#!/usr/bin/env bash
#
# Shared normalization for storage-layout JSON. Sourced by both
# `check-storage-layouts.sh` (CI diff) and `update-storage-layouts.sh`
# (fixture regeneration) so both sides apply the SAME transformation.
#
# What gets stripped:
#   - `astId` fields on `.storage[]` and `.types[].members[]`.
#   - AST-ID suffixes inside type identifiers `t_contract(X)NN`,
#     `t_struct(X)NN_storage`, `t_enum(X)NN`, `t_userDefinedValueType(X)NN`.
#     These IDs change on any unrelated source edit.
#
# What is PRESERVED:
#   - Array lengths in `t_array(...)NN_storage` (a fixed-size array changing
#     from e.g. [1e9] to [1e8] is a load-bearing regression).
#   - Everything else (labels, slots, offsets, byte counts, encodings).
#
# The transformation is applied recursively — AST IDs inside `.types[].base`,
# `.types[].value`, `.types[].key`, and `.types[].members[].type` are all
# stripped. Missing any of these locations would cause false CI diffs on
# unrelated source edits.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/_normalize-storage-layout.sh"
#   normalize < input.json > output.json

normalize() {
  jq -S '
    def strip_astids:
      gsub("t_contract\\((?<n>[^)]+)\\)[0-9]+"; "t_contract(\(.n))")
      | gsub("t_struct\\((?<n>[^)]+)\\)[0-9]+_storage"; "t_struct(\(.n))_storage")
      | gsub("t_enum\\((?<n>[^)]+)\\)[0-9]+"; "t_enum(\(.n))")
      | gsub("t_userDefinedValueType\\((?<n>[^)]+)\\)[0-9]+"; "t_userDefinedValueType(\(.n))");
    .storage |= map(del(.astId)) |
    .storage |= map(.type |= strip_astids) |
    .types = (
      (.types // {})
      | with_entries(.key |= strip_astids)
      | with_entries(
          .value.base? |= (if . then strip_astids else . end)
          | .value.value? |= (if . then strip_astids else . end)
          | .value.key? |= (if . then strip_astids else . end)
          | .value.members? |= (
              if . then map(del(.astId) | .type |= strip_astids) else . end
            )
        )
    )
  '
}
