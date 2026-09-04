# gateway-sdk-kit

Dependency-free Swift package holding the gateway-independent half of the tacogips gateway client SDKs: the neutral schema catalog model, SDL printing, regex schema search, the operation-to-GraphQL-document builder, the argv builder for command-style gateways, and the lexer-aware GraphQL variable inliner.

Consumed by wrike-gateway, google-analytics-gateway, apple-gateway, gmail-gateway, and google-documents-gateway through their `<Name>GatewaySDK` facades, and by riela's gateway add-ons.

See `design-docs/briefs/gateway-sdk-kit-2026-09-04.md` for the design.
