#!/usr/bin/env bash

SESSION_NAME="remu"

if tmux has-session -t "$SESSION_NAME"; then
    echo "Session $SESSION_NAME already exists"
    exit 1
fi

tmux new-session -d -s "$SESSION_NAME" -n "Editor"
tmux send-keys -t "$SESSION_NAME:0" "nix develop ./devshells/default -c zsh" C-m
tmux send-keys -t "$SESSION_NAME:0" "clear && nvim ." C-m

tmux new-window -t "$SESSION_NAME" -n "Build"
tmux send-keys -t "$SESSION_NAME:1" "nix develop ./devshells/default -c zsh" C-m
tmux send-keys -t "$SESSION_NAME:1" "clear" C-m

tmux new-window -t "$SESSION_NAME" -n "Cross-toolchain"
tmux send-keys -t "$SESSION_NAME:2" "cd ./tests/traps && nix develop ../../devshells/riscv -c zsh" C-m
tmux send-keys -t "$SESSION_NAME:2" "clear" C-m

tmux select-window -t "$SESSION_NAME:0"
tmux attach -t "$SESSION_NAME"
