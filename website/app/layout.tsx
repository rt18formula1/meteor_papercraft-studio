import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Meteor PaperCraft Studio — 写真を、組み立てられる形へ。",
  description: "写真からローカルで3D/CADモデルを構築し、ペーパークラフト展開図まで作るmacOSアプリ。",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}
