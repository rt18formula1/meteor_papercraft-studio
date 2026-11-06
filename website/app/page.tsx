import Image from "next/image";

const steps = [
  { number: "01", title: "写真を集める", text: "身の回りのものを、角度を変えて撮影。画像はあなたのMacから外へ出しません。" },
  { number: "02", title: "形を読む", text: "Visionとローカル3D推定が、輪郭・断面・寸法・部品候補を読み取ります。" },
  { number: "03", title: "CADへ整える", text: "OpenCascade系のB-Rep、ロフト、プリミティブで、壊れにくい形状へ再構築します。" },
  { number: "04", title: "紙へ展開する", text: "面を分解し、折り線・カット線・接着タブ付きのA4 PDFへ変換します。" },
];

export default function Home() {
  return (
    <main>
      <nav className="nav shell">
        <a className="brand" href="#top" aria-label="Meteor PaperCraft Studio home">
          <span className="brand-mark" aria-hidden="true"><i /><i /><i /></span>
          <span>Meteor <b>PaperCraft</b> Studio</span>
        </a>
        <div className="nav-links"><a href="#workflow">仕組み</a><a href="#local">ローカル完結</a><a href="#download">開発状況</a></div>
        <a className="nav-cta" href="#download">制作の進捗を見る <span>↗</span></a>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero-copy">
          <p className="eyebrow"><span className="live-dot" /> LOCAL-FIRST / CAD-READY</p>
          <h1>写真を、<em>組み立てられる</em><br />形へ。</h1>
          <p className="hero-lede">Meteor PaperCraft Studioは、写真からローカルで3D/CADモデルを構築し、最後は手で組み立てられる展開図にするmacOSアプリです。</p>
          <div className="hero-actions"><a className="button button-primary" href="#workflow">変換の流れを見る <span>↓</span></a><a className="text-link" href="#local">クラウドへ送らない理由 <span>↘</span></a></div>
          <div className="hero-meta"><span><strong>5+</strong> views</span><span><strong>100%</strong> local</span><span><strong>CAD</strong> grade path</span></div>
        </div>
        <div className="hero-art" aria-label="紙とCADモデルを表現したビジュアル">
          <div className="orbit orbit-one" /><div className="orbit orbit-two" />
          <div className="model-card"><span className="card-label">MODEL / SPARK F1</span><div className="wire-car"><div className="car-body" /><div className="car-nose" /><div className="car-wing" /><div className="wheel wheel-a" /><div className="wheel wheel-b" /><div className="wheel wheel-c" /><div className="wheel wheel-d" /></div><span className="dimension dim-x">145 mm</span><span className="dimension dim-y">62 mm</span><span className="crosshair">+</span></div>
          <div className="paper-card"><span>UNFOLD / 04</span><div className="paper-fold fold-a" /><div className="paper-fold fold-b" /><div className="paper-fold fold-c" /><b>A4 / 100%</b></div>
          <div className="hero-stamp">NO<br /><small>UPLOAD</small></div>
        </div>
      </section>

      <section className="manifesto shell" id="local"><div className="manifesto-label">WHY METEOR</div><div><h2>便利なだけの<br /><span>画像生成</span>ではない。</h2><p>写真の見た目を真似るのではなく、寸法を持つ形状として読み直す。作ったモデルを眺めるだけで終わらせず、紙に出して、手で確かめる。</p></div><div className="manifesto-note"><span>01 / 03</span><b>YOUR FILES<br />STAY HERE.</b><small>外部AI APIに画像を送らない。ローカル推定、ローカルCAD、ローカル出力。</small></div></section>

      <section className="workflow shell" id="workflow"><div className="section-head"><p className="eyebrow">FROM IMAGE TO OBJECT</p><h2>形になるまでを、<br /><em>一つの流れ</em>に。</h2></div><div className="steps">{steps.map((step) => <article className="step" key={step.number}><div className="step-number">{step.number}</div><h3>{step.title}</h3><p>{step.text}</p><span className="step-line" /></article>)}</div></section>

      <section className="proof shell"><div className="proof-copy"><p className="eyebrow">A REAL WORKBENCH</p><h2>試作の画面から、<br /><em>製品の形へ。</em></h2><p>Spark F1のサンプルを出発点に、背景除去、多視点3D、CADフィーチャ、展開図までの一貫した制作環境を育てています。</p><a className="text-link" href="#download">開発方針を読む <span>↗</span></a></div><div className="screen-frame"><Image src="/studio-screen.png" alt="Meteor PaperCraft Studioの開発中画面" fill sizes="(max-width: 900px) 100vw, 55vw" /></div></section>

      <section className="reference shell"><div className="reference-image"><Image src="/spark-reference.png" alt="Spark F1模型のサンプル写真" fill sizes="(max-width: 900px) 100vw, 42vw" /></div><div className="reference-copy"><p className="eyebrow">THE FIRST BENCHMARK</p><h2>最初の基準は、<br /><em>手元のSpark。</em></h2><p>専用テンプレートで終わらせず、任意の物体へ広げるための基準モデル。車体、タイヤ、ウイングを部品として捉え、CADから紙へ落とし込みます。</p><div className="specs"><span><b>5</b> views</span><span><b>145</b> mm target</span><span><b>01</b> local kernel</span></div></div></section>

      <section className="download shell" id="download"><div><p className="eyebrow">BUILDING IN PUBLIC, LOCALLY</p><h2>つくる人のMacに、<br /><em>そのまま置ける。</em></h2><p>配布版はPythonやHomebrewを要求しない、ローカル3Dバックエンド同梱のmacOS arm64アプリとして仕上げます。</p></div><div className="download-card"><div className="download-top"><span className="brand-mark small"><i /><i /><i /></span><span>METEOR / MACOS ARM64</span></div><strong>PaperCraft Studio</strong><span className="download-status"><i /> bundled backend / in progress</span><a className="button button-light" href="#top">制作の進捗を追う <span>↗</span></a></div></section>

      <footer className="footer shell"><span>© 2026 Meteor PaperCraft Studio</span><span>LOCAL BY DEFAULT / MADE TO BE BUILT</span><a href="#top">BACK TO TOP ↑</a></footer>
    </main>
  );
}
