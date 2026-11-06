# Meteor PaperCraft Studio promo site plan

## Design

- **Style candidates:** Industrial editorial 0.07; Soft craft atelier 0.06; Precision instrument 0.05.
- **Chosen direction:** Industrial editorial with craft warmth.
- **Design movement:** A dark product-film landing page where precision CAD diagrams meet tactile paper surfaces.
- **Core principles:** show the transformation, make local-first privacy visible, use measured geometry as a visual language, keep calls to action concrete.
- **Color philosophy:** near-black graphite for the engineering workspace, warm paper ivory for trust and craft, and electric mint as the ownable signal for local processing.
- **Layout paradigm:** asymmetrical editorial bands with an offset hero visual, numbered process rail, and a diagonal paper fold motif instead of centered card grids.
- **Signature elements:** dotted measurement lines, folded-corner panels, and small monospace status labels.
- **Interaction:** restrained hover lifts and reveal-on-scroll feel like inspecting a model rather than browsing a SaaS dashboard.
- **Animation:** slow grain/float on the hero model, 180ms card transitions, no looping distraction.
- **Typography:** Geist/Inter for UI copy paired with IBM Plex Mono for dimensions and process labels.
- **Brand essence:** local CAD-grade papercraft studio for makers who want a real printable object from their own photos. Precise, private, hands-on.
- **Brand voice:** direct, technical, optimistic. Example: “写真を、寸法のある形へ。” / “クラウドへ送らず、組み立てられるところまで。”
- **Wordmark:** Meteor starburst mark built from three folded triangles around a small dot.
- **Signature brand color:** electric mint `#A5F3D0`.

## Implementation

- Plain local Next.js App Router project under `website/`.
- Single responsive landing page with supplied studio screenshot and Spark reference photo.
- Static route manifest at `/manus-routes.json`.
- No analytics, login, API, or hosted service dependencies.
