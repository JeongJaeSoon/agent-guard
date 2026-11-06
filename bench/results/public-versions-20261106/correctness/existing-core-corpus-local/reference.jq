def protocol_discriminator($key): . as $v
    | ($key == "type" or $key == "media_type" or $key == "mimeType"
       or $key == "encoding")
      and (["text","image","document","search_result","browser_state",
            "tool_reference","tool_use","tool_result","thinking",
            "redacted_thinking","base64","url","file","content","pdf",
            "image/png","image/jpeg","image/gif","image/webp",
            "application/pdf","text/plain"]
           | map(. == $v) | any);
def shape_safe_walk(f): def w($key):
      if type == "object"
      then with_entries(. as $e | .value = ($e.value | w($e.key)))
      elif type == "array" then map(w(null))
      elif type == "string" and protocol_discriminator($key) then .
      else f
      end;
    w(null);
def binary_media_type: . as $v
    | (["image/png","image/jpeg","image/gif","image/webp","application/pdf"]
       | map(. == $v) | any);
def binary_block:
      type == "object"
      and (((.type == "image" or .type == "document")
            and (.source | type) == "object"
            and .source.type == "base64"
            and (.source.data | type) == "string"
            and (.source.media_type | binary_media_type))
           or (.type == "image"
               and (.file | type) == "object"
               and (.file.base64 | type) == "string"
               and (.file.type | binary_media_type))
           or (.type == "pdf"
               and (.file | type) == "object"
               and (.file.base64 | type) == "string")
           or (.type == "image"
               and (.data | type) == "string"
               and (.mimeType | binary_media_type)));
def binary_payload_path:
      if has("source") then ["source", "data"]
      elif has("file") then ["file", "base64"]
      else ["data"]
      end;
def binary_payload_paths: . as $root
    | [[], paths]
    | map(select(. as $p | $root | getpath($p) | binary_block))
    | map(. as $p | $p + ($root | getpath($p) | binary_payload_path));
def strip_binary_payloads:
      reduce binary_payload_paths[] as $p (.; setpath($p; ""));
def restore_binary_payloads($orig):
      reduce ($orig | binary_payload_paths[]) as $p
        (.; setpath($p; $orig | getpath($p)));
.secrets as $secrets | .response | 
    def specs($s):
      $s
      | map(if type == "string"
            then {literal: ., replacement: "[REDACTED]", contextual: false}
            elif (type == "object"
                  and (.literal | type) == "string"
                  and (.replacement | type) == "string")
            then (. + {contextual: (.contextual == true)})
            else empty
            end);
    def context_replace($literal; $replacement):
      if contains($literal)
      then (. / $literal) as $parts
           | reduce range(1; $parts | length) as $i ($parts[0];
               . + (if ($parts[$i] | test("^([ \t\n,;]|$)"))
                    then $replacement
                    else $literal
                    end)
                 + $parts[$i])
      else .
      end;
    def prepare_specs($specs):
      {contextual: ($specs | map(select(.contextual))
                    | sort_by(.literal | length) | reverse),
       ordinary: ($specs | map(select(.contextual | not))
                  | sort_by(.literal | length) | reverse)};
    def redact($plan):
      reduce $plan.contextual[] as $x (.;
          if ($x.literal | length) > 0
          then context_replace($x.literal; $x.replacement)
          else .
          end)
      | reduce $plan.ordinary[] as $x (.;
        if ($x.literal | length) > 0
        then ((. / $x.literal) | join($x.replacement))
        else .
        end);
    (specs($secrets)) as $specs
    | (reduce (.. | strings) as $leaf
         (0; . + ($leaf | length) + 1)) as $string_work
    # Literal replacement is proportional to spec-count × response size.
    # Bound that work below the host hook timeout. High-cardinality output is
    # still fail-closed in one tree walk by masking every nonempty string leaf.
    # Both walks are key-aware: a detected literal that happens to equal a
    # protocol token would otherwise break the response shape here for exactly
    # the reason JQ_SHAPE_SAFE_WALK describes, on the precise path too.
    | if ($specs | length) > 256
         or (($specs | length) * $string_work) > 8000000
      then shape_safe_walk(if type == "string" and length > 0
                           then "[REDACTED]" else . end)
      # Ordering belongs to the response, not each string leaf. Reuse one
      # immutable plan while preserving contextual-first, longest-first order.
      else prepare_specs($specs) as $plan
           | shape_safe_walk(if type == "string" and length > 0
                             then redact($plan) else . end)
      end
  