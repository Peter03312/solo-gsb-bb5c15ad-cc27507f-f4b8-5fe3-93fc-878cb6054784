#!/usr/bin/env bash
# 设备组可调谐支持集合示例（需服务已启动，默认 http://localhost:8000）
#
# 演示本轮能力：
#   1) 录入组时可选填 supported_frequencies；未填与既有组视为支持场次全部频点
#   2) 读取组信息返回有效支持集合与配置修订号 config_revision
#   3) 按组变更支持集合须携带所见修订号；过期拒绝（409），不覆盖新配置
#   4) 发布规划/锁定遵守各组当前支持集合
#   5) 能力变化使旧的占用调整快照失效；预演/确认遵守当前能力
#   6) 逐组切换路线的端点与每个临时步骤都遵守支持集合；旧版不可用时报涉及组
#   7) 实测批次照实留存不支持的频点并标记异常；已固化批次不重算
set -euo pipefail

BASE="${BASE:-http://localhost:8000}"
jq_get() { python3 -c 'import json,sys; print(json.load(sys.stdin)'"$1"')'; }

echo "== 1. 创建场次（可用频点 1..7） =="
SESSION=$(curl -s -X POST "$BASE/sessions" \
  -H 'Content-Type: application/json' \
  -d '{"name": "能力演示", "frequencies": [1, 2, 3, 4, 5, 6, 7]}')
echo "$SESSION"
SID=$(echo "$SESSION" | jq_get '["id"]')

echo "== 2. 录入组：组1/组3 不填支持频点（继承全场次），组2 只支持 4/5/6/7 =="
G1=$(curl -s -X POST "$BASE/sessions/$SID/groups" -H 'Content-Type: application/json' \
  -d '{"name": "音响", "start": 0, "end": 120}' | jq_get '["id"]')
G2=$(curl -s -X POST "$BASE/sessions/$SID/groups" -H 'Content-Type: application/json' \
  -d '{"name": "窄带灯光", "start": 60, "end": 180,
       "supported_frequencies": [4, 5, 6, 7]}' | jq_get '["id"]')
G3=$(curl -s -X POST "$BASE/sessions/$SID/groups" -H 'Content-Type: application/json' \
  -d '{"name": "返送", "start": 120, "end": 240}' | jq_get '["id"]')
echo "G1=$G1 G2=$G2 G3=$G3"

echo "== 3. 读取组信息：有效支持集合 + 配置修订号（新组修订号均为 1） =="
curl -s "$BASE/sessions/$SID/groups/$G2"; echo

echo "== 4. 非法支持集合整次拒绝（400）：空集合 / 含场次外频点 =="
curl -s -o /dev/null -w 'empty -> %{http_code}\n' -X POST \
  "$BASE/sessions/$SID/groups" -H 'Content-Type: application/json' \
  -d '{"name": "坏", "start": 0, "end": 60, "supported_frequencies": []}'
curl -s -o /dev/null -w 'out-of-session -> %{http_code}\n' -X POST \
  "$BASE/sessions/$SID/groups" -H 'Content-Type: application/json' \
  -d '{"name": "坏", "start": 0, "end": 60, "supported_frequencies": [1, 99]}'

echo "== 5. 录入干扰关系（组1-组2、组2-组3 最小间距均为 3） =="
curl -s -o /dev/null -X POST "$BASE/sessions/$SID/interferences" \
  -H 'Content-Type: application/json' \
  -d "{\"group_a\": $G1, \"group_b\": $G2, \"min_separation\": 3}"
curl -s -o /dev/null -X POST "$BASE/sessions/$SID/interferences" \
  -H 'Content-Type: application/json' \
  -d "{\"group_a\": $G2, \"group_b\": $G3, \"min_separation\": 3}"

echo "== 6. 发布 v1：组2 只支持 4..7，字典序最小分配为 (1,4,1) =="
curl -s -X POST "$BASE/sessions/$SID/plans" \
  -H 'Content-Type: application/json' \
  -d '{"base_version": 0, "locks": []}'; echo

echo "== 7. 锁定到组不支持的频点（组2 锁 1）-> 400，整次拒绝 =="
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/sessions/$SID/plans" \
  -H 'Content-Type: application/json' \
  -d "{\"base_version\": 1, \"locks\": [{\"group_id\": $G2, \"frequency\": 1}]}"

echo "== 8. 按组变更组2 的支持集合为 {1,2,3}，携带所见修订号 1 =="
curl -s -X PUT "$BASE/sessions/$SID/groups/support" \
  -H 'Content-Type: application/json' \
  -d "{\"groups\": [{\"group_id\": $G2, \"config_revision\": 1,
        \"supported_frequencies\": [1, 2, 3]}]}"; echo

echo "== 9. 再用旧修订号 1 提交 -> 409 revision_conflict，不覆盖新配置 =="
curl -s -X PUT "$BASE/sessions/$SID/groups/support" \
  -H 'Content-Type: application/json' \
  -d "{\"groups\": [{\"group_id\": $G2, \"config_revision\": 1,
        \"supported_frequencies\": [1, 2]}]}"; echo

echo "== 10. 能力收缩后旧发布版 v1 保持原样，重发规划必须落在新能力内 =="
# v1 的组2=4 已不被支持；新规划 (4,1,4) 是当前能力下的解
curl -s -X POST "$BASE/sessions/$SID/plans" \
  -H 'Content-Type: application/json' \
  -d '{"base_version": 1, "locks": []}'; echo
curl -s "$BASE/sessions/$SID/plans/1" | python3 -c '
import json,sys
print("历史 v1 保持原样:",
      {a["group_id"]: a["frequency"] for a in json.load(sys.stdin)["assignments"]})'

echo "== 11. 能力变化使旧占用调整快照失效 =="
TOKEN=$(curl -s -X POST "$BASE/sessions/$SID/occupations/preview" \
  -H 'Content-Type: application/json' -d '{}' | jq_get '["snapshot_token"]')
# 再次变更能力（修订号 2 -> 3），旧令牌立即作废
curl -s -o /dev/null -X PUT "$BASE/sessions/$SID/groups/support" \
  -H 'Content-Type: application/json' \
  -d "{\"groups\": [{\"group_id\": $G2, \"config_revision\": 2,
        \"supported_frequencies\": [1, 2, 3, 7]}]}"
curl -s -o /dev/null -w '旧快照确认 -> %{http_code}（409 snapshot_conflict）\n' \
  -X POST "$BASE/sessions/$SID/occupations/confirm" \
  -H 'Content-Type: application/json' \
  -d "{\"snapshot_token\": \"$TOKEN\"}"

echo "== 12. 逐组切换：旧版在当前能力下不可用时，422 报告涉及组 =="
curl -s -X POST "$BASE/sessions/$SID/retune" \
  -H 'Content-Type: application/json' \
  -d '{"start_version": 1, "target_version": 2}' \
  | python3 -c '
import json,sys
d = json.load(sys.stdin)["detail"]
print("error:", d["error"])
print("start.unsupported:", d["start"]["unsupported"])'

echo "== 13. 实测批次：频点不被组支持也照实留存，并标记 unsupported_frequency =="
# 依据 v2（组2=1，而组2 当前支持 {1,2,3,7}，频点 1 合法；故意让组3 报 7？）
# 这里提交组2=5：5 在场次频点内但组2 不支持 -> 照实留存 + 异常标记
curl -s -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 2, \"batch_no\": 1, \"readings\": [
        {\"group_id\": $G1, \"frequency\": 4},
        {\"group_id\": $G2, \"frequency\": 5},
        {\"group_id\": $G3, \"frequency\": 4}]}" \
  | python3 -c '
import json,sys
d = json.load(sys.stdin)
print("unsupported:", d["unsupported_frequencies"])
print("anomalies :", d["anomalies"])
print("readings  :", d["readings"])'
echo "已固化批次后续不再因能力变化重算（读取 /measurements/1 始终为同一结论）。"
