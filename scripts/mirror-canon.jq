# Canonical, AST-ID-FREE, ARRAY-LENGTH-PRESERVING rendering of a storage layout.
#
# Input : a storage-layout object {storage:[...], types:{...}} (raw solc output,
#         NOT the normalized golden fixture — this gate reads compiled artifacts).
# Args  : $root — "contract" to canonicalise .storage[]  (VeHemi itself)
#                 "struct:<Name>" to canonicalise the members of that struct
#                 (the library mirror lives inside t_struct(VeHemiLayout)NN_storage)
# Output: one TSV row per top-level member:  label \t slot \t offset \t canonical-type
#
# The canonical-type is a RECURSIVE rendering of the type entry:
#     <label>|<encoding>|<numberOfBytes>[{member@slot:offset=<canonical-type>,...}][base=..][val=..]
# `label` is solc's human-readable type name ("uint256[37]",
# "mapping(uint256 => uint64)", "struct VeHemiStorageV2.LockedPoint"). It carries
# NO AST ids and DOES carry array lengths, so this comparison is stable across
# unrelated source edits yet blind to nothing that moves a byte.
#
# ONE deliberate equivalence: `contract IFoo` == `address`. The mirror declares
# plain `address` so it need not import every interface; both are a 20-byte
# inplace slot. Nothing else is equated.

def canonical_type($types; $typeId; $depth):
  ($types[$typeId]) as $entry
  | if $entry == null then "MISSING_TYPE(" + $typeId + ")"
    elif $depth <= 0 then "DEPTH_LIMIT"
    else
      ( if ($entry.label // "") | startswith("contract ") then "address" else ($entry.label // "?") end )
      + "|" + ($entry.encoding // "?")
      + "|" + (($entry.numberOfBytes // "?")|tostring)
      + ( if ($entry.members // null) != null
          then "{" + ([ $entry.members[]
                        | .label + "@" + (.slot|tostring) + ":" + (.offset|tostring)
                          + "=" + canonical_type($types; .type; $depth - 1) ] | join(",")) + "}"
          else "" end )
      + ( if ($entry.base // null) != null then "[base=" + canonical_type($types; $entry.base; $depth - 1) + "]" else "" end )
      + ( if ($entry.key  // null) != null then "[key="  + canonical_type($types; $entry.key;  $depth - 1) + "]" else "" end )
      + ( if ($entry.value// null) != null then "[val="  + canonical_type($types; $entry.value;$depth - 1) + "]" else "" end )
    end;

(if (.storageLayout // null) != null then .storageLayout else . end) as $layout
| ($layout.types // {}) as $types
| ( if $root == "contract"
    then ($layout.storage // [])
    else ( $types
           | to_entries
           | map(select(.key | test("t_struct\\(" + ($root | ltrimstr("struct:")) + "\\)")))
           | if length == 0 then [] else (.[0].value.members // []) end )
    end )
| .[]
| [ .label, (.slot|tostring), (.offset|tostring), canonical_type($types; .type; 8) ]
| @tsv
