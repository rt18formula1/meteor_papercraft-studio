# Netlify公開方針

プロモーションサイトは、GitHubリポジトリの`website/`をNetlifyのビルド対象として公開する。Meteor PaperCraft Studio本体のmacOSソースと、Next.jsプロモーションサイトを同じリポジトリで管理し、サイトだけをNetlifyで継続デプロイする。

`netlify.toml`で次を指定済み。

- Base directory: `website`
- Build command: `npm run build`
- Node.js: 20
- Next.js用Netlifyプラグイン

GitHubへPush後、Netlifyで「Import an existing project」から対象リポジトリを選択し、設定を自動検出させる。`netlify.toml`があるため、Base directoryとBuild commandは手入力不要。公開URLが確定したら、アプリのダウンロード導線とサイトのCTAへ反映する。

## 公開後の運用

`main`へのPushでNetlifyが自動ビルドする。プルリクエストごとにDeploy Previewを作り、トップページの表示、画像、`/manus-routes.json`、モバイル幅の4点を確認する。サイトにはAPIキーやユーザーデータを置かず、静的な製品紹介として運用する。
