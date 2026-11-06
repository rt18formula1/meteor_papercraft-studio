# Meteor PaperCraft Studio — 追加ビルドエラー報告

## ビルド実行コマンド

```bash
cd "/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio"
./scripts/build-app.sh
ls -l "dist/Meteor PaperCraft Studio.app/Contents/MacOS/MeteorPaperCraftStudio"
open "dist/Meteor PaperCraft Studio.app"
```

## 1. コンパイルエラー

**対象ファイル：**

`/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio/Sources/MeteorPaperCraftStudio/main.swift`

**該当行：402**

エラー：
```text
error: cannot convert value of type 'LocalAIError' to expected argument type 'String'
```

該当コード：
```swift
switch result {
case .success(let mesh):
    status.stringValue="ローカル3Dメッシュを生成しました。展開しています…"
    exportMeshPDF(from:mesh)
case .failure(let message):
    status.stringValue="ローカル3Dに失敗しました"
    showAlert("ローカル3D生成に失敗しました",message)
}
```

### 原因

`result` の失敗側で受け取っている `message` の型は `String` ではなく `LocalAIError` です。一方、`showAlert` の第2引数は `String` を要求しているため、型が一致していません。

## 2. ビルド成果物の確認エラー

実行コマンド：
```bash
ls -l "dist/Meteor PaperCraft Studio.app/Contents/MacOS/MeteorPaperCraftStudio"
```

結果：
```text
No such file or directory
```

## 3. アプリケーション起動エラー

実行コマンド：
```bash
open "dist/Meteor PaperCraft Studio.app"
```

結果：
```text
The application cannot be opened because its executable is missing.
```

## 4. 修正・確認事項

- `LocalAIError` を `String` に変換してから `showAlert` に渡す。
- `LocalAIError` の定義を確認し、適切なエラーメッセージを取得する。
- 修正後に `./scripts/build-app.sh` を再実行する。
- ビルド成功後、アプリケーション内の実行ファイルが生成されていることを確認する。
- 最後にアプリケーションが正常に起動することを確認する。


## 修正済み（2026-11-04）

`LocalAIError` をそのまま `showAlert` の文字列引数へ渡していたため、`message.localizedDescription` を渡すように修正した。これで `LocalAIError` と `String` の型不一致を解消する。

Mac側で再実行するコマンド：

```sh
cd "/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio"
./scripts/build-app.sh
ls -l "dist/Meteor PaperCraft Studio.app/Contents/MacOS/MeteorPaperCraftStudio"
open "dist/Meteor PaperCraft Studio.app"
```

再びエラーが出た場合：

```sh
./scripts/build-app.sh 2>&1 | tee build.log
```


## MLX実行時エラー修正（2026-11-04）

MLX-MASt3Rの読み込み時に `No module named 'cv2'` が発生していた。`cv2`を提供する `opencv-python` を `scripts/setup-local-3d.sh` の明示的な依存に追加した。ランナーも、cv2不足時には一般的な「MLX未インストール」ではなくOpenCV不足と表示するよう修正した。

Mac側で仮想環境を有効にした状態だけを補修する場合：

```sh
"$HOME/.meteor-papercraft/local3d/.venv/bin/python" -m pip install opencv-python
```

推奨はセットアップスクリプトの再実行：

```sh
cd "/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio"
./scripts/setup-local-3d.sh
./scripts/build-app.sh
open "dist/Meteor PaperCraft Studio.app"
```


## スクリーンショット診断（2026-11-04 10:09）

MLX-MASt3Rのモデル読み込み、5画像20ペアの処理、粗位置合わせ、微調整まで完了している。失敗は推論ではなく、`--output-mesh` のOpen3D読み込み時に発生した。

原因：Open3DのmacOSネイティブ依存 `libusb-1.0.0.dylib` が `/opt/homebrew/opt/libusb/lib/` に存在しない。

修正：`setup-local-3d.sh` がHomebrewの `libusb` をインストールまたは再インストールするよう変更。ランナーもlibusb不足時に具体的なコマンドを表示するよう変更。

Mac側で以下を実行する：

```sh
brew install libusb
cd "/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio"
./scripts/setup-local-3d.sh
./scripts/build-app.sh
open "dist/Meteor PaperCraft Studio.app"
```

モデルのダウンロードや5画像の再推定は正常に進んでいるため、次回はlibusb修復後に同じ処理を再実行すれば、Open3Dのメッシュ化へ進む。


## 配布パッケージ化（2026-11-04 10:31）

最新スクリーンショットでもMLX-MASt3Rの推定は最後まで完了しており、失敗はOpen3Dが `/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib` を見つけられないことだった。販売用にターミナルやHomebrewを要求しないため、次の構成へ変更した。

- `build-app.sh` がローカル `.venv` を `Contents/Resources/local3d/.venv` へ同梱
- `libusb-1.0.0.dylib` を `Contents/Frameworks` へ同梱
- Open3D dylibのlibusb参照をアプリ内rpathへ書き換え
- Swiftアプリは同梱Pythonを最優先し、開発用ホームディレクトリ環境は最後のフォールバックに変更
- `DYLD_LIBRARY_PATH`、`HF_HOME`、`XDG_CACHE_HOME`をアプリ実行時に設定
- 巨大な推論ログは `reconstruction.log` に保存し、アラートには末尾6,000文字だけ表示
- `scripts/package-distribution.sh`で顧客向けZIPを作成

開発者側で一度だけセットアップ後、次のコマンドで顧客配布物を作る：

```sh
cd "/Users/Ryusei_Tsukamoto/Documents/ChatGPT/Meteor PaperCraft Studio"
./scripts/setup-local-3d.sh
./scripts/package-distribution.sh
```

生成物：`dist/Meteor-PaperCraft-Studio-macOS-arm64.zip`。顧客側は解凍してアプリを開くだけで、ターミナル操作は不要。
