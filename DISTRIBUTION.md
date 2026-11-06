# Meteor PaperCraft Studio 配布手順

このプロジェクトは、開発者のMacで一度だけローカル3Dバックエンドを準備し、その後はアプリ内へPython環境・MLX-MASt3R・Open3D・OpenCV・libusbを同梱したZIPを生成する方式です。顧客や自分の別Macでは、ZIPを解凍してアプリを起動するだけにします。

## 開発者Macでの一度だけの準備

Apple Silicon Macで、プロジェクトのルートから次を実行します。

```sh
./scripts/setup-local-3d.sh
```

既存の仮想環境をコピー型で作り直したい場合だけ、次を使います。モデルキャッシュは削除されません。

```sh
METEOR_REBUILD_VENV=1 ./scripts/setup-local-3d.sh
```

## 自分用・顧客用のZIP生成

```sh
./scripts/package-distribution.sh
```

生成物は次です。

```text
dist/Meteor-PaperCraft-Studio-macOS-arm64.zip
```

このZIPには次が含まれます。

- macOS arm64アプリ本体
- 同梱Python仮想環境
- MLX-MASt3Rとその依存関係
- Open3D、OpenCV、CadQuery
- Open3Dが必要とするlibusb dylib
- ローカル推定ランナーとCAD補助スクリプト

初回の3D生成時だけ、モデルウェイトをHugging Faceから取得します。取得後はApplication Supportへキャッシュされます。画像推定とメッシュ生成はローカルで行い、外部推論APIは使いません。

## macOS配布時の注意

このプロトタイプのZIPはApple Silicon向けです。販売版ではDeveloper ID署名、公証、インストーラまたはDMG、プライバシー説明、モデルウェイトのライセンス確認を追加します。現段階では、まず同梱バックエンドが開発者Macと別のMacで起動できることを確認してから、公証工程へ進みます。
