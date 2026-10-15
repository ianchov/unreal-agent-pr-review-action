# Cost in USD of one model_response usage record, or null when it cannot be priced.
# OpenRouter reports the charge itself; Anthropic is priced from $prices (USD per million tokens).
def call_cost($prices; $model):
  .Raw as $r
  | if $r.cost != null then
      $r.cost + (if $r.is_byok then ($r.cost_details.upstream_inference_cost // 0) else 0 end)
    else
      (($r.input_tokens // 0) + ($r.cache_creation_input_tokens // 0) + ($r.cache_read_input_tokens // 0)) as $prompt
      | (($prices[$model] // []) | map(select(.max_prompt_tokens == null or $prompt <= .max_prompt_tokens)) | first) as $t
      | if $t == null or $r.input_tokens == null then null
        else
          (($r.input_tokens * $t.input
            + ($r.cache_creation.ephemeral_5m_input_tokens // $r.cache_creation_input_tokens // 0) * $t.cache_write_5m
            + ($r.cache_creation.ephemeral_1h_input_tokens // 0) * $t.cache_write_1h
            + ($r.cache_read_input_tokens // 0) * $t.cache_read
            + ($r.output_tokens // 0) * $t.output) / 1000000)
          * (if ($r.inference_geo // "global") == "global" then 1 else 1.1 end)
        end
    end;
