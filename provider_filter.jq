[
  .[] |
  . as $p | 
  .resourceTypes[] |
  {
    type: ($p.namespace + "/" + .resourceType), 
    apiVersion: (.apiVersions | max), 
    state: $p.registrationState,
    id: ("/subscription/{subscriptionId}/providers/" + $p.namespace + "/" + .resourceType)
  }
] |
group_by(.state) |
[
  .[] |
  { (.[0] | .state): sort_by(.id) }
] |
add
