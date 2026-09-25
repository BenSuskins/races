#!/usr/bin/env bash
set -euo pipefail

: "${RACES_API_TOKEN:?Set RACES_API_TOKEN before running this script}"
api_url="${RACES_API_URL:-https://races-api.suskins.co.uk}"
weights_id="${RACES_BACKTEST_WEIGHTS_ID:-}"
from_date="${RACES_BACKTEST_FROM:-}"
to_date="${RACES_BACKTEST_TO:-}"

request=$(jq -cn \
  --arg weightsID "$weights_id" \
  --arg from "$from_date" \
  --arg to "$to_date" \
  --argjson variants '[
    {"name":"proportional","overrides":{"overroundMethod":"proportional"}},
    {"name":"power","overrides":{"overroundMethod":"power"}},
    {"name":"value-edge-3","overrides":{"minimumValueEdge":0.03}},
    {"name":"value-edge-5","overrides":{"minimumValueEdge":0.05}},
    {"name":"value-edge-8","overrides":{"minimumValueEdge":0.08}},
    {"name":"value-probability-5","overrides":{"minimumValueProbability":0.05}},
    {"name":"value-probability-8","overrides":{"minimumValueProbability":0.08}},
    {"name":"value-probability-12","overrides":{"minimumValueProbability":0.12}}
  ]' \
  '{variants:$variants}
   + (if $weightsID == "" then {} else {weightsID:$weightsID} end)
   + (if $from == "" then {} else {from:$from} end)
   + (if $to == "" then {} else {to:$to} end)')

response=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${RACES_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -X POST \
  --data "$request" \
  "${api_url}/v1/backtests")

jq -r '
  .id as $reportID
  | .sweep.sharedCorpusID as $corpusID
  | "report \($reportID) corpus \($corpusID)",
  (["report_id", "weights_id", "from", "to", "variant", "races", "high SR", "value SR", "fav SR", "value ROI", "market LL"] | @tsv),
  (.sweep.reports[] | [
    ($reportID | tostring),
    .report.weightsID,
    .report.from,
    .report.to,
    .name,
    (.report.highestProbability.races // 0 | tostring),
    (if .report.highestProbability.strikeRate == null then "" else ((.report.highestProbability.strikeRate * 1000 | round) / 10 | tostring) end),
    (if .report.valueSelection.strikeRate == null then "" else ((.report.valueSelection.strikeRate * 1000 | round) / 10 | tostring) end),
    (if .report.favourite.strikeRate == null then "" else ((.report.favourite.strikeRate * 1000 | round) / 10 | tostring) end),
    (if (.report.valueSelection.roi.bets // 0) > 0
      then (((((.report.valueSelection.roi.returned / .report.valueSelection.roi.bets) - 1) * 1000 | round) / 10) | tostring)
      else ""
     end),
    (if .report.marketLogLoss == null then "" else ((.report.marketLogLoss * 1000 | round) / 1000 | tostring) end)
  ] | @tsv)
' <<<"${response}"
