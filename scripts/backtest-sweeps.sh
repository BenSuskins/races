#!/usr/bin/env bash
set -euo pipefail

: "${RACES_API_TOKEN:?Set RACES_API_TOKEN before running this script}"
api_url="${RACES_API_URL:-https://races-api.suskins.co.uk}"

response=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${RACES_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -X POST \
  --data '{"variants":[
    {"name":"proportional","overrides":{"overroundMethod":"proportional"}},
    {"name":"power","overrides":{"overroundMethod":"power"}},
    {"name":"value-edge-3","overrides":{"minimumValueEdge":0.03}},
    {"name":"value-edge-5","overrides":{"minimumValueEdge":0.05}},
    {"name":"value-edge-8","overrides":{"minimumValueEdge":0.08}},
    {"name":"value-probability-5","overrides":{"minimumValueProbability":0.05}},
    {"name":"value-probability-8","overrides":{"minimumValueProbability":0.08}},
    {"name":"value-probability-12","overrides":{"minimumValueProbability":0.12}}
  ]}' \
  "${api_url}/v1/backtests")

jq -r '
  "corpus \(.sweep.sharedCorpusID)",
  (["variant", "races", "high SR", "value SR", "value ROI", "market LL"] | @tsv),
  (.sweep.reports[] | [
    .name,
    (.report.highestProbability.races | tostring),
    ((.report.highestProbability.strikeRate // 0) * 100 | floor | tostring),
    ((.report.valueSelection.strikeRate // 0) * 100 | floor | tostring),
    (if (.report.valueSelection.roi.bets // 0) > 0
      then (((.report.valueSelection.roi.returned / .report.valueSelection.roi.bets) - 1) * 100 | floor | tostring)
      else "—"
     end),
    (.report.marketLogLoss // 0 | tostring)
  ] | @tsv)
' <<<"${response}"
