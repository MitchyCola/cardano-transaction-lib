#!/usr/bin/env bash

msg=$(
    cat <<EOF
/*
                                **WARNING**


This is an autogenerated Nix file! Do not edit by hand!


Modifications to autogenerated Nix code can be made by running:

  \`make autogen-deps\`

in the repository root, after completing one or more of the following:

For Purescript dependencies:

  - Edit \`spago.dhall\`

For JS dependencies:

  - Edit \`package.json\`
  - Remove the symlinked \`node_modules\`
  - Run \`npm i --package-lock-only\`


*/
EOF
)

for file in spago-packages.nix node-packages.nix node2nix.nix node-env.nix; do
    printf '%s\n' "$msg" "$(cat $file)" >"$file"
done

# echo "$msg"
