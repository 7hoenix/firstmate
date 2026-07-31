# shellcheck shell=bash
# Shared TOON output encoder for agent-facing projections.
# Usage: . bin/fm-toon-lib.sh   then   printf '%s\n' "$MODEL" | fm_toon_encode
#
# TOON is the default agent-facing format per the AXI standard; a projection
# keeps its internal data model in JSON and encodes at the output boundary only,
# so TOON and `--json` stay parity representations of one model.
#
# This library is the ONE owner of the encoder. It was extracted from
# bin/fm-bearings-snapshot.sh when bin/fm-rounds-queue.sh needed the same
# encoding: two copies of the quoting rules would drift the moment only one was
# corrected, and the quoting rules are the part that is easy to get subtly wrong.
#
# Scope: the projections that use it emit a flat object of scalar fields plus
# arrays of uniform scalar objects, so the encoder implements exactly three TOON
# forms - object scalars, the tabular array form (`key[N]{fields}:` plus comma
# rows at +2 indent), and the empty-array form (`key: []`). It deliberately does
# not implement nested objects or ragged arrays; a caller needing those should
# flatten its model rather than extend this encoder quietly.
#
# Quoting follows the TOON spec: a string is quoted when it is empty, has
# leading/trailing whitespace, would otherwise read as a bare boolean/null/
# number, contains a structural character, contains a control character, or
# starts with a dash.
#
# Reads JSON on stdin, writes TOON on stdout. Returns non-zero if jq fails.

fm_toon_encode() {
  jq -r '
    def q:
      tostring
      | if (. == "")
          or test("^\\s|\\s$")
          or (. == "true" or . == "false" or . == "null")
          or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
          or test("[:\"\\\\\\[\\]{},]")
          or test("[[:cntrl:]]")
          or test("^-")
        then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
        else . end;
    def scal:
      if . == null then "null"
      elif type == "boolean" then (if . then "true" else "false" end)
      elif type == "number" then tostring
      else q end;
    def emit($k; $v):
      if ($v | type) == "array" then
        if ($v | length) == 0 then "\($k): []"
        else
          ($v[0] | keys_unsorted) as $ks
          | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
              ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
        end
      else "\($k): " + ($v | scal)
      end;
    [ to_entries[] | emit(.key; .value) ] | join("\n")
  '
}
