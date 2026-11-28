#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
source_dir="$root/windows/src/gaocaozuo/assets/mascots"
destination="$1/ShortcutMascots"
mkdir -p -- "$destination"
for role in chatgpt claude gemini grok deepseek kimi glm qwen; do
    [[ -s "$source_dir/$role.png" ]]
    cp -- "$source_dir/$role.png" "$destination/$role.png"
done
