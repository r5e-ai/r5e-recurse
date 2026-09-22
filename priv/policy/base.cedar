// These labels describe the managed profile's cooperative custody limit.
permit(principal, action == Recurse::Action::"admit", resource)
when {
  context.authority_present &&
  context.node_acyclic &&
  context.task_scope_valid &&
  (context.target_kind != "SessionBinding" && context.target_kind != "ContextManifest" ||
    context.custody == "runtime-held" &&
    context.profile == "cooperative-local" &&
    context.signer_reachability == "same-user-cooperative-limit") &&
  (context.target_kind != "SessionBinding" ||
    context.binding_valid &&
    context.session_key == context.binding_signer &&
    context.badge_subject == context.binding_signer &&
    context.delegation_subject == context.binding_signer &&
    context.span_actor == context.binding_signer)
};
