# 画面の書き方と、サーバーとのやり取り

grilling のラウンドで、案を画面に出してクリックで選んでもらうための手引き。サーバーは `screen_dir` の最新の HTML を frame(右上の操作バーとテーマ)で包んで返し、ユーザーの操作を `state_dir` に書く。

## 画面の入れ物

`screen_dir` に 1 画面 1 ファイルで書く。

- **断片(既定)**: `<h2>` などの中身だけを書く。サーバーが `scripts/frame-template.html` に入れ、操作バー・テーマ・通信の script を足す。
- **完全な文書**: 先頭が `<!DOCTYPE` か `<html` のファイルは包まず、通信の script だけを足す。操作バー(コピー・コメント・微調整)は付かない。図を自前の CSS で描くときだけ使う。完全な文書から操作を送るには `window.grillVisual.send({ type: 'click', choice: '…' })` を呼ぶ。
- ファイル名は意味のある名前(`layout.html`)にし、使い回さない。直したものは `layout-v2.html` に書く。いちばん新しい `.html` が出る。ファイルは作成ツールで書き、heredoc で端末に流さない。
- 画像などの付属ファイルは `screen_dir` に置き、`/files/<ファイル名>` で参照する。`screen_dir` の外は読めない。

## 起動と状態

```bash
bash scripts/start.sh --project-dir /path/to/project
# {"type":"server-started","pid":…,"port":52341,"url":"http://127.0.0.1:52341/?key=…",
#  "screen_dir":"…/.grill-visual/<id>/content","state_dir":"…/.grill-visual/<id>/state"}
```

- `--project-dir` を付けると `.grill-visual/` にセッションを置き、停止後も画面が残る。付けなければ OS の一時ディレクトリで、停止すると消える。`.grill-visual/` は対象リポジトリの `.gitignore` に入れる。
- サーバーはブラウザを開かない。最初の画面を書いたら `open-url <url>` で渡す(開けなければクリップボード、それも無理なら URL を出す)。
- URL の `?key=` は認証の鍵。削らずに丸ごと渡す。初回に開くとブラウザの cookie に移り、以後の更新や `/files/` は鍵なしで通る。
- サーバーは `127.0.0.1` だけで待ち受け、外のホストへは何も送らない。URL が別の端末から開けないのは仕様。
- 裏で動くプロセスを回収する環境では `--foreground` を付け、呼び出し側のバックグラウンド実行に載せる。
- 起動に失敗すると `{"error": "…"}` を返す。書かれたログ(`state_dir/server.log`)を読んで原因を直す。
- 生きているかは `state_dir/server-info` があり `state_dir/server-stopped` が無いことで分かる。操作が無いまま 4 時間(`--idle-minutes` で変更)、または起動元のプロセスが消えると自動で止まり、止まった理由は `server-stopped` に残る。止まっていたら同じ `--project-dir` で起動し直し、新しい URL を渡す。

## ループ

1. 画面ファイルを書く(サーバーの生存を先に確かめる)。
2. 端末で、URL・画面の要約 1 行・「選んだら右上の『指示をコピー』で貼ってください」を伝えてターンを終える。
3. 次のターンで `state_dir/instruction.md`(コピーされる指示文の最新版)と `state_dir/events`(クリックの履歴)を読む。ユーザーが端末に貼った文を主、`instruction.md` を従、`events` を補いとして合成する。どれも無ければ操作していない。
4. 画面が変わるなら新しいファイルを書く。画面を出すたびに前の画面の `events` と `instruction.md` は消える。
5. 端末の質問に戻るときは待機画面(`waiting.html`)を出し、解決済みの選択肢を見せ続けない。

```html
<div style="display:flex;align-items:center;justify-content:center;min-height:60vh">
  <p class="lede">端末で続けています…</p>
</div>
```

## 最小の画面

```html
<h2>どちらの配置が読みやすいか</h2>
<p class="lede">読みやすさと視線の流れで選んでください</p>

<div class="pick-list">
  <div class="pick" data-choice="single" data-recommended>
    <div class="pick-mark">A</div>
    <div class="pick-body"><h3>1 カラム</h3><p>読むことに集中できる</p></div>
  </div>
  <div class="pick" data-choice="double">
    <div class="pick-mark">B</div>
    <div class="pick-body"><h3>2 カラム</h3><p>サイドバーから移動できる</p></div>
  </div>
</div>
```

`<script>` も `onclick` も要らない。`data-choice` を持つ要素を押すと選択状態になり、操作が記録される。

## 部品(frame の CSS クラス)

### 選択肢

- `pick-list`: 選択肢を縦に並べる入れ物。中に `pick` を置く。
- `pick`: 1 つの選択肢。`data-choice="<id>"` を付ける。中は `pick-mark`(A・B のような印)と `pick-body`(`h3` と `p`)。
- `pick-grid`: 視覚で比べる案を並べる入れ物(列は幅に合わせて増減)。中に `pick-tile` を置く。
- `pick-tile`: 1 つの選択肢。上に `pick-visual`(図や画面の絵を入れる枠)、下に `pick-body`(`h3` と `p`)。

選択肢の属性:

- `data-recommended`: 推奨の案に付ける。frame が「推奨」の印を付け、初めて開いたときに選んだ状態にする(1 つだけ選ぶ問いで複数付けたら先頭だけ)。印を `h3` に手で書かない(指示文の案の名前に混ざる)。
- `data-question="…"`: `pick-list` / `pick-grid` に付ける。問いが複数ある画面で、指示文の問いの名前になる。
- `data-multiselect`: `pick-list` / `pick-grid` に付けると複数選べる。

frame は各選択肢に補足の欄を、各入れ物の最後に別案(その他)の欄を足す。

### 見せるための入れ物

- `sketch`: 画面や図の枠。`sketch-title`(枠の見出し)と `sketch-body`(中身)を持つ。
- `side-by-side`: 子を 2 列に並べて比べる(狭い幅では 1 列)。
- `tradeoff`: 利点と欠点を 2 列に並べる。中に `tradeoff-good`(`h4` と `ul`)と `tradeoff-bad`(同)を置く。

### wireframe の部品

`wf-nav`(上のナビ帯)、`wf-side`(サイドバー)、`wf-main`(本文の領域)、`wf-button`、`wf-input`、`wf-blank`(中身が未定の枠)。配置の質問は、これらと文字だけで描く。

### 文字と区切り

`h2`(画面の題)、`h3`(見出し)、`lede`(題の下の補足)、`block`(下に余白のある塊)、`caption`(小さな注記)。

## 右上の操作バー

本文の上に浮かぶバーに、接続の点・回答の進み具合(「2 / 3 問」。押すと未回答の問いへ移る)・コメント・微調整・「指示をコピー」の分割ボタンが並ぶ。分割ボタンは左がそのままコピー、右の山形がコピーされる指示のプレビューと画面全体への指示の欄を開く。

- 指示文の形は、何をしてほしいかの 1 段落と、XML タグで区切った中身。`<screen>`(画面のファイル)、`<decisions>`(問いごとの `<question>` と、選んだ案の `<chosen id="<data-choice>" recommended="true">`、答えていない問いは `unanswered="true"`)、続けて中身のあるものだけ `<comments>`・`<tweaks>`・`<overall>`。ユーザーの自由文はエスケープして載せ、指示の構造と取り違えさせない。
- **選んだ案への補足**: 案を選ぶとその案の中に補足欄が開く。書いた文は `<addendum>` として載り、選択は外れない。
- **別案**: 1 つだけ選ぶ問いでは「どれでもない別案」。書くとほかの選択が外れ、選択肢を押すと書いた文が消える。
- **要素へのコメント**: 「コメント」(キー `C`)を押してから要素を押すと番号付きのピンが立ち、「案「A」の「保存」」のように要素の名前付きで `<comment>` に載る。
- **微調整**: 次の節。
- 選択・補足・コメント・微調整の値はタブの sessionStorage に画面ごとに残り、再読み込みや同じ画面の書き直しでは消えない。選択肢は Tab で移って Enter / Space で選べ、矢印キーで同じ問いの中を移り、数字キー 1〜9 で、フォーカスのある問い(無ければ未回答の最初の問い)の n 番目を選ぶ。
- ユーザーが画面を触ると同じ指示文がサーバーへ送られ、`state_dir/instruction.md` に最新の 1 本として書かれる。

## 微調整(角丸・余白・色をスライダーで動かす)

数値で詰めたい見た目は、CSS を CSS 変数で書き、触ってよい値を `data-tweaks` の中に input で宣言する。frame は input を操作バーの下に浮かぶパネルへ移し(頭をつかんで動かせる。本文は動かさない)、動かすと変数をその場で書き換える。

```html
<style>
  .demo { border-radius: var(--card-radius, 12px); padding: var(--card-pad, 16px); }
  .demo button { background: var(--btn, #181818); }
</style>
<div class="demo">…</div>

<div data-tweaks>
  <input type="range" name="--card-radius" data-label="角丸" data-unit="px" min="0" max="24" step="1" value="12">
  <input type="range" name="--card-pad" data-label="余白" data-unit="px" min="8" max="32" step="2" value="16">
  <input type="color" name="--btn" data-label="ボタンの色" value="#181818">
</div>
```

- `name` が書き換える CSS 変数、`value` が今の値(指示文の「→」の左)、`data-label` がパネルと指示文での呼び名、`data-unit` が値に付ける単位。
- 変数は既定で `#frame-content` に付く。案ごとに別の値にしたいときは `data-scope=".card-a .demo"` のように付け先を選ぶ。
- `input` の type は range・color・number、または `select`。
- 宣言のある画面だけバーに「微調整」が出る。右の余白に収まる幅のときだけ開いた状態で始まり、以後は開閉と置いた位置を覚える。

## events の形

`state_dir/events` は 1 行 1 JSON。クリックのたびに追記され、新しい画面を出すと消える。

```jsonl
{"timestamp":1706000101,"type":"click","choice":"a","text":"案 A 1 カラム","id":null}
{"timestamp":1706000108,"type":"click","choice":"c","text":"案 C グリッド","id":null}
```

クリックの順は迷いの跡でもある。最後の `choice` が最終の選択とは限らないので、迷っていそうなら聞き返す。ユーザーの返答を主にし、events は補いに使う。

## 画面を書くときの心得

- 質問の忠実度に合わせる。配置の質問は wireframe、仕上がりの質問だけ作り込む。
- 各画面の先頭に、何を判断してほしいかを書く(「どれか選んで」ではなく「どのレイアウトが業務向けに見えるか」)。
- 選択肢は 2〜4 個。
- 写真など実データが判断を左右する題材は、placeholder ではなく実データを使う。
- 図の中身は、グラデーションや装飾ラベルに頼らず、余白と文字の大きさで階層を作る。

## 片付け

```bash
bash scripts/stop.sh <session_dir>
```

`--project-dir` 付きのセッションは画面が `.grill-visual/` に残り、一時ディレクトリのセッションは消える。

## 関連ファイル

- frame とテーマの CSS: `scripts/frame-template.html`
- 画面側の通信(reload の受信・操作の送信): `scripts/client.js`
- 指示文・コメント・微調整の動き: `scripts/companion-ui.js`
- サーバー: `scripts/serve.cjs`
