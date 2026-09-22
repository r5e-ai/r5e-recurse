# Session admission implementation boundary

`SessionBinding.admit/4` uses a current SessionKeys generation, validates the scoped credential pair and local required fields, then admits an AgentSession and SessionBinding through a trusted submit-once driver. The driver must journal before submission and invoke its signing callback only for a new operation. The operation ID derives from origin, actor, generation and target Kind. An uncertain retry resolves the existing operation; it must not mint another nonce.

Canonical reads return `spec`, `target`, `actor`, and the exact `signed` envelope. The AgentSession payload omits its server-assigned name; its resource reference is derived from its admission event and returned separately. The binding is content-named. Both returned records retain their canonical target fields.

A failure after span admission returns `incomplete` with that span's immutable event reference. Ambiguous submissions and failed confirmation retain `outcome_unknown` plus an operation handle. The module does not enable routes or substitute an admission receipt for launch intent.

Tests use the gateway AgentSession KindDefinition copied byte-for-byte from enterprise revision 28b4c4444abffa47873872c13597cc1a27b9890f. Other deployment fixtures retain their explicitly minimal schemas. The real-policy tests create distinct ephemeral keys and subject-countersigned credentials, enforce Task scope, and cover key-process death, unknown acknowledgements, required fields and canonical confirmation failure. The synchronous fixture driver is not durable; R5E-216 supplies the journaled HTTP driver and its integration test.
