#!/bin/zsh
set -euo pipefail

# Backward-compatible entry point. The maintained installer owns the complete
# process topology (HTTP API, normalization/materialization worker, cloud relay,
# watchdog, export, and backup) plus versioned releases and rollback.
script_dir="${0:A:h}"
print -- "install_receiver_macos.zsh 已合并到 configure_receiver_macos.zsh；现在使用完整的多进程架构。"
exec "$script_dir/configure_receiver_macos.zsh" install --mode agent "$@"
