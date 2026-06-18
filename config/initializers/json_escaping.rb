# Escape <, >, and & in all `to_json` output as \uXXXX. The dashboard embeds
# survey and results JSON inside <script type="application/json"> tags; without
# this, attacker-influenced text (a card title, a respondent's region label)
# containing "</script>" could close the tag early and inject markup. The
# escaped form still parses identically via JSON.parse on the client.
ActiveSupport.escape_html_entities_in_json = true
