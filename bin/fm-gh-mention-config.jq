# Validate and flatten config/gh-mentions.json for bin/fm-gh-mention.sh.
#
# Prints, on success:
#   <enabled>\n<may_open_pr>\n--trusted\n<login>...\n--markers\n<marker>...\n--repos\n<owner/name>...
# and otherwise the single line "invalid: <reason>". There is deliberately no
# repair path: a typo in trusted_logins would silently widen or narrow who
# firstmate obeys, so an unreadable field stops the plane instead.

def login_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$");
def repo_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$");
# A marker is compared as a literal substring, so whitespace or a leading dash
# would either never match a real comment or collide with this format's own
# section separators.
def marker_ok: type == "string" and (length > 0) and (test("[[:space:]]") | not) and (startswith("-") | not);

def known: ["enabled", "trusted_logins", "markers", "repos", "may_open_pr"];

def problem:
  if type != "object" then "must be a JSON object"
  elif ((keys - known) | length) > 0 then "has unknown key(s): " + ((keys - known) | join(", "))
  elif (.enabled | type) != "boolean" then "needs a boolean \"enabled\""
  elif (.trusted_logins | type) != "array" then "needs an array \"trusted_logins\""
  elif (.trusted_logins | length) == 0 then "needs at least one login in \"trusted_logins\""
  elif any(.trusted_logins[]; login_ok | not) then "has a \"trusted_logins\" entry that is not a GitHub login"
  elif (.markers != null) and ((.markers | type) != "array" or (.markers | length) == 0)
    then "needs \"markers\" to be a non-empty array when present"
  elif (.markers != null) and any(.markers[]; marker_ok | not)
    then "has a \"markers\" entry that is empty, contains whitespace, or starts with a dash"
  elif (.repos != null) and ((.repos | type) != "array")
    then "needs \"repos\" to be an array when present"
  elif (.repos != null) and any(.repos[]; repo_ok | not)
    then "has a \"repos\" entry that is not owner/name"
  elif (.may_open_pr != null) and ((.may_open_pr | type) != "boolean")
    then "needs \"may_open_pr\" to be a boolean when present"
  else null
  end;

if problem then "invalid: " + problem
else
  [(.enabled | tostring), ((.may_open_pr // false) | tostring), "--trusted"]
  + (.trusted_logins | map(.))
  + ["--markers"] + ((.markers // ["@firstmate", "@captain"]) | map(.))
  + ["--repos"] + ((.repos // []) | map(.))
  | join("\n")
end
