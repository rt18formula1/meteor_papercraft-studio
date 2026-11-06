

## Netlify / macOS integration update (2026-11-06)

Netlify failed because the existing site UI had `website` as the publish directory while `website` was also the base directory. The repository now sets `publish = ".next"` in `netlify.toml`; an existing Netlify site must also change its UI Publish directory to `.next` so the UI override does not win.

The macOS app now retains its `StudioController`, implements `application(_:openFiles:)`, and accepts `.meteorcraft` files opened from Finder. The app bundle declares the custom project UTI and file extension in `Info.plist`, so a saved project can be double-clicked to launch the app and restore its photos/settings.
