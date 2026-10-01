#!/usr/bin/env bash
# 设备组可调谐能力（支持频点）与配置修订号：本轮新增能力的端到端调用示例。
#
# 前置：服务已启动（docker compose up，或本地 uvicorn），默认地址 localhost:8000。
# 用法：bash examples/capabilities.sh [BASE_URL]
#
# 流程：
#   1) 建场次/组（可选填支持频点，未填视为支持全部）+ 干扰关系
#   2) 读取组信息（支持集合 + 配置修订号）
#   3) 首版规划遵守各组能力
#   4) 携带所见修订号收窄能力；过期/非法提交被拒绝
#   5) 历史发布版保持原样；旧版在当前能力下不可用时 retune 报告涉及组
#   6) 重新规划得到能力内新版
#   7) 占用调整：能力变化使旧预演快照失效（409）
#   8) 能力导致无解时 422，占用与当前发布版不变
#   9) 实测批次照实留存不支持频点并标记异常；已固化批次不重算
set -euo pipefail

BASE="${1:-http://localhost:8000}"
CURL="curl -sS"

say() { printf '\n=== %s ===\n' "$1"; }
post() { $CURL -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; echo; }
put()  { $CURL -X PUT  "$BASE$1" -H 'Content-Type: application/json' -d "$2"; echo; }
get()  { $CURL "$BASE$1"; echo; }

say "1. 创建场次（可用频点 1..6）"
SID=$(post /sessions '{"name":"能力演示","frequencies":[1,2,3,4,5,6]}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "session_id=$SID"

say "2. 录入设备组：a 不填（=全部）、b 仅支持 {4,5,6}、c 不填"
GA=$(post "/sessions/$SID/groups" '{"name":"a","start":0,"end":120}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
GB=$(post "/sessions/$SID/groups" \
      '{"name":"b","start":60,"end":180,"supported_frequencies":[4,5,6]}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
GC=$(post "/sessions/$SID/groups" '{"name":"c","start":120,"end":240}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "group ids: a=$GA b=$GB c=$GC"

# 录入时支持频点必须是场次可用频点的非空子集
say "2b. 非法能力（含场次外频点 99）-> 400"
post "/sessions/$SID/groups" \
  '{"name":"坏能力","start":0,"end":10,"supported_frequencies":[3,99]}'

post "/sessions/$SID/interferences" \
  "{\"group_a\":$GA,\"group_b\":$GB,\"min_separation\":3}" >/dev/null

say "3. 读取组 b：支持集合 + 当前配置修订号（初始为 0）"
get "/sessions/$SID/groups/$GB"

say "4. 首版规划：只能用各组支持频点 -> (a,b,c)=(1,4,1)"
post "/sessions/$SID/plans" '{"base_version":0,"locks":[]}'

say "4b. 锁定频点 3（不在 b 的能力 {4,5,6} 内）-> 400"
post "/sessions/$SID/plans" \
  "{\"base_version\":1,\"locks\":[{\"group_id\":$GB,\"frequency\":3}]}"

say "5. 过期修订号收窄能力 -> 409（不覆盖新配置）"
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[5,6],"revision":5}'

say "5b. 携带所见修订号 0 收窄 b 到 {5,6} -> 成功，修订号自增为 1"
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[5,6],"revision":0}'

say "5c. 非法子集 {5,7} -> 400，修订号不前进"
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[5,7],"revision":1}'

say "6. 历史发布版 v1 保持原样（b 仍为 4，尽管其现已不支持 4）"
get "/sessions/$SID/plans/1"

say "6b. 旧版 v1 在当前能力下不可用：retune 422 并指出涉及组 b"
post "/sessions/$SID/retune" \
  '{"start_version":1,"target_version":1,"fixed_groups":[]}'

say "7. 重新规划（base_version=1）：能力内新版 (1,5,1)，仅 b 改频"
post "/sessions/$SID/plans" '{"base_version":1,"locks":[]}'

say "8. 占用调整预演（当前能力一致，无违规）"
PV=$(post "/sessions/$SID/occupations/preview" \
     '{"register":[{"frequency":6,"start":0,"end":200}]}')
echo "$PV"
TOKEN=$(echo "$PV" | python3 -c 'import sys,json;print(json.load(sys.stdin)["snapshot_token"])')

say "8b. 再收窄 b 到 {5}（修订号 1->2）"
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[5],"revision":1}'

say "8c. 用旧快照确认 -> 409 snapshot_conflict（能力变化，快照失效，不落任何变更）"
post "/sessions/$SID/occupations/confirm" \
  "{\"snapshot_token\":\"$TOKEN\",\"register\":[{\"frequency\":6,\"start\":0,\"end\":200}]}"

say "9. 能力导致无解：补 b-c 干扰后把 b、c 都收窄到 {5,6}"
post "/sessions/$SID/interferences" \
  "{\"group_a\":$GB,\"group_b\":$GC,\"min_separation\":3}" >/dev/null
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[5,6],"revision":2}' >/dev/null
put "/sessions/$SID/groups/$GC/supported" \
  '{"frequencies":[5,6],"revision":3}' >/dev/null
post "/sessions/$SID/plans" '{"base_version":2,"locks":[]}'

say "9b. 无解后当前发布版仍是 v2（不自动重写）"
get "/sessions/$SID/plans"

say "10. 实测批次：b=4 场次可用但不支持（unsupported）、a=9 场次外（unavailable）；
     c=1 在其当前 {5,6} 能力之外，同样照实标记"
post "/sessions/$SID/measurements" "{\"plan_version\":2,\"batch_no\":1,\"readings\":[
  {\"group_id\":$GA,\"frequency\":9},
  {\"group_id\":$GB,\"frequency\":4},
  {\"group_id\":$GC,\"frequency\":1}]}"

say "10b. 放宽 b 能力后，已固化批次不重算（仍是提交时的核对结果）"
put "/sessions/$SID/groups/$GB/supported" \
  '{"frequencies":[4,5,6],"revision":4}' >/dev/null
get "/sessions/$SID/measurements/1"

echo
echo "完成。"
