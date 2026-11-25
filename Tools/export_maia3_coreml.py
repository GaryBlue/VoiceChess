"""Export and numerically check the fixed-shape Maia3 5M Core ML model.

Use a Python 3.10+ environment and install `Tools/maia3-coreml-requirements.txt`.
Download the checkpoint with `maia3-cache --model maia3-5m`, then run this script
with --checkpoint and --out.
"""

import argparse
from collections import deque

import coremltools as ct
import numpy as np
import torch
import chess

from maia3.dataset import tokenize_board, get_historical_tokens
from maia3.models import MHA
from maia3.uci import load_model, parse_args
from maia3.utils import get_all_possible_moves, mirror_move


def coreml_compatible_attention(self, query, key=None, value=None, need_weights=False,
                               attn_mask=None, **kwargs):
    """Static-shape equivalent of Maia3's nn.MultiheadAttention call for 5M."""
    bias = None
    if self.use_gab:
        bias = self._sq_bias(query).reshape(-1, 64, 64)
    elif self.use_relative_bias:
        bias = self.relative_bias().unsqueeze(0).expand(1, -1, -1, -1)
        bias = bias.contiguous().view(-1, 64, 64)

    if attn_mask is not None:
        mask = attn_mask.to(dtype=query.dtype)
        bias = mask if bias is None else bias + mask

    # Maia3-5M has a fixed batch of one, 64 board tokens, 256 channels, and
    # eight heads. Constants avoid symbolic aten::Int nodes in traced MHA.
    batch, length, embed, heads, head_dim = 1, 64, 256, 8, 32
    qkv = torch.nn.functional.linear(query, self.mha.in_proj_weight, self.mha.in_proj_bias)
    qkv = qkv.reshape(batch, length, 3, heads, head_dim).permute(2, 0, 3, 1, 4)
    q, k, v = qkv[0], qkv[1], qkv[2]
    scores = torch.matmul(q, k.transpose(-2, -1)) * (head_dim ** -0.5)
    if bias is not None:
        scores = scores + bias.reshape(batch, heads, length, length)
    weights = torch.softmax(scores, dim=-1)
    attended = torch.matmul(weights, v).transpose(1, 2).reshape(batch, length, embed)
    return self.mha.out_proj(attended), None


MHA.forward = coreml_compatible_attention


def check_attention_equivalence():
    torch.manual_seed(7)
    attention = MHA(256, 8, 0.0, use_gab=False).eval()
    query = torch.randn(1, 64, 256)
    bias = torch.randn(8, 64, 64)
    with torch.no_grad():
        reference = attention.mha(query, query, query, attn_mask=bias)[0]
        converted = coreml_compatible_attention(
            attention, query, query, query, attn_mask=bias
        )[0]
    difference = float((reference - converted).abs().max())
    print("attention max abs diff", difference)
    if difference > 1e-5:
        raise RuntimeError("Static attention differs from Maia's original MHA implementation")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    check_attention_equivalence()

    cfg = parse_args([
        "--model", "maia3-5m", "--checkpoint-path", args.checkpoint,
        "--device", "cpu", "--no-use-amp",
    ])
    model = load_model(cfg).eval()

    class MovePolicy(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, tokens, self_elo, opponent_elo):
            move_logits, _, _ = self.inner(tokens, self_elo.long(), opponent_elo.long())
            return move_logits

    wrapped = MovePolicy(model).eval()
    example = (
        torch.zeros((1, 64, 97), dtype=torch.float32),
        torch.tensor([1500.0], dtype=torch.float32),
        torch.tensor([1500.0], dtype=torch.float32),
    )
    with torch.no_grad():
        eager = wrapped(*example)
        traced = torch.jit.trace(wrapped, example, check_trace=True)
        traced_scores = traced(*example)
    print("traced max abs diff", float((eager - traced_scores).abs().max()))

    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="tokens", shape=(1, 64, 97), dtype=np.float32),
            ct.TensorType(name="self_elo", shape=(1,), dtype=np.float32),
            ct.TensorType(name="opponent_elo", shape=(1,), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="move_logits")],
        minimum_deployment_target=ct.target.iOS16,
    )
    mlmodel.save(args.out)
    coreml = ct.models.MLModel(args.out, compute_units=ct.ComputeUnit.CPU_ONLY)

    history_board = chess.Board()
    history = deque([tokenize_board(history_board)], maxlen=cfg.history)
    for san in ("e4", "e5", "Nf3", "Nc6"):
        history_board.push_san(san)
        history.append(tokenize_board(history_board))
    positions = [
        chess.Board(),
        chess.Board("rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        history_board.copy(),
        chess.Board("7k/P7/8/8/8/8/8/7K w - - 0 1"),
        chess.Board("7k/8/8/8/8/8/p7/7K b - - 0 1"),
    ]
    all_moves = get_all_possible_moves()
    move_index = {move: i for i, move in enumerate(all_moves)}
    for i, board in enumerate(positions):
        hist = history if i == 2 else deque([tokenize_board(board)], maxlen=cfg.history)
        tokens = get_historical_tokens(hist, cfg, 0, 0, 0, 0).unsqueeze(0).numpy().astype(np.float32)
        legal_indices = []
        for move in board.legal_moves:
            uci = move.uci()
            if board.turn == chess.BLACK:
                uci = mirror_move(uci)
            legal_indices.append(move_index[uci])
        elo_scores = {}
        for elo in (800, 1000, 1200):
            inputs = {
                "tokens": tokens,
                "self_elo": np.array([elo], dtype=np.float32),
                "opponent_elo": np.array([elo], dtype=np.float32),
            }
            with torch.no_grad():
                torch_scores = wrapped(
                    torch.from_numpy(inputs["tokens"]),
                    torch.from_numpy(inputs["self_elo"]),
                    torch.from_numpy(inputs["opponent_elo"]),
                ).numpy()
            coreml_scores = coreml.predict(inputs)["move_logits"]
            diff = np.abs(torch_scores - coreml_scores)
            torch_best = int(legal_indices[np.argmax(torch_scores[0, legal_indices])])
            coreml_best = int(legal_indices[np.argmax(coreml_scores[0, legal_indices])])
            print(f"position {i}, Elo {elo}: max abs diff={diff.max():.6g}, legal-best torch/coreml={all_moves[torch_best]}/{all_moves[coreml_best]}")
            elo_scores[elo] = coreml_scores
        elo_difference = np.abs(elo_scores[800] - elo_scores[1200]).max()
        print(f"position {i}: Elo 800/1200 max score delta={elo_difference:.6g}")
        if elo_difference == 0:
            raise RuntimeError("Elo conditioning does not affect Core ML model outputs")


if __name__ == "__main__":
    main()
