---
name: agent-orchestrate
description: "tmux または Herdr の pane で動く worker(codex / claude / pi)へ実装を委譲し、完了報告のレビューと再依頼を繰り返してゴールまで進めるときに使う。pane で動くエージェントへメッセージを確実に届ける手順(transport の選択、Enter の分離、着弾確認、時刻指定の送信)も持つ。「オーケストレーションモードで」と明示されたら、以降のセッションで通常タスクを毎回 worker へ委譲するモードに入る。「ペインに送って」「codex に報告して」「Claude に完了を伝えて」「4 時に codex に Enter を送って」のような依頼でも使う。in-process の subagent(Agent tool など)とは別で、pane worker への委譲と pane への送信を扱う。"
---

# agent-orchestrate

## GOAL

orchestrator(この skill を読んでいるエージェント)が、tmux または Herdr の worker エージェントと
「タスク投函 → 実装 → 完了報告 → レビュー → 修正依頼 → …」のキャッチボールを、
最初に固定したゴールを達成するまで繰り返す。

```
orchestrator (例: claude %4 / orchestrator w1:p1)    worker (例: codex %0 / reviewer w2:p1)
  │ 1. ゴール設定・タスクファイル作成          │
  │ 2. pane へタスク投函 ───────────────────▶│ 3. 実装・検証
  │    (ターンを終了して待つ)                  │ 4. レポート書き出し
  │◀────────────── 5. pane へ報告着弾 ─────────│
  │ 6. レビュー(diff精読 + 検証エビデンス照合) │
  │ 7. 合格 → 仕上げ / 不合格 → 2 へ戻る       │
```

`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パス。

## オーケストレーターモード（セッション常駐の役割分担）

ユーザーが「オーケストレーションモードで」「オーケストレーターになって」「Opus をオーケストレーターにして」
のように**明示したときだけ**入るモード。明示がない通常の依頼では発動しない。task ファイルを投函されて
worker として起動されたセッションも、このモードには入らない(PRIMARY RULES「worker の再委譲は task ファイルの明示があるときだけ」)。

- **モデルに依存しない**。どのモデルでも、この skill を読んでいるセッションがそのまま orchestrator になる。
  モデル名は入口の呼び方が違うだけで、手順・rule・完了条件は同一である。モデル名を条件に手順を分岐させない。
- 入る前に「2. 自分のペイン確認」の前提チェック(tmux か Herdr の中にいること)を通す。前提を満たさないセッションでは
  モードに入れないので、勝手に代替手段へ切り替えず、ユーザーに tmux / Herdr 内での起動を依頼して停止する。
- モード中は、そのセッションの調査・実装・検証などの通常タスクを、都度の指示がなくても毎回この skill で worker (codex / claude / pi) へ委譲する。
- orchestrator が自分で行うのは、ゴール設定、タスクファイル作成、レビュー、検証、判定、コミット、ユーザーへの最終報告。差し戻しより速く判断の要らない機械的な直し（目安 10 行程度までの lint・format・型の小さな直し、テスト 1〜2 本の補い、規約合わせ）は自分で直してよい。判断が残る直し・振る舞いの変更・同種の直しの反復は worker に差し戻し、task ファイルに直し方を書く。直した内容は commit 本文に書く。
- 組み合わせ例:
  - 実装: `implementer` に委譲 → orchestrator が diff 精読と検証エビデンス照合でレビュー
  - 原因調査: `investigator` に委譲 → orchestrator が仮説を批判的にレビュー → 修正は新しい `implementer` へ投函
  - 大きめの変更: `implementer` → 独立 `reviewer` にもう 1 往復 → orchestrator が最終判定
  - 受入確認だけ: `verifier` に委譲 → orchestrator が結果を裏取りして報告
- モードの解除はユーザーの明示指示による(「オーケストレーションモード終了」など)。

## PRIMARY RULES

- **ポーリング禁止**。sentinel ファイルの監視ループや sleep ループを張らない(トークンを無限に消費する)。
  タスクを投函したら**ターンを終了**し、worker からの報告がユーザーメッセージとして着弾するのを待つ。
  そのために、**タスク指示に完了・ブロック時の報告義務を必ず含める**(報告手段は [references/delivery.md](references/delivery.md))。
- **委譲先は tmux / Herdr の pane worker に限る**。orchestrator 側のランタイムが in-process の sub-agent 機構
  (Claude Code の Agent / Task / Workflow tool 等)を持っていても、この skill のキャッチボールには使わない。
  route manifest・courier・done マーカーによる報告経路は pane worker 前提であり、in-process sub-agent では
  「新規セッション」「報告の着弾駆動」「pane の cleanup」がいずれも成立しない。worker として起動するコマンド
  (`codex` / `claude` / `pi` から選ぶ。詳細は Workflow 2 参照)は自由に選んでよい。
- **ゴールを最初に固定する**。完了条件(仕様項目・変更ファイル一覧・完了報告)をタスクファイルに明文化し、
  レビュー合格条件 = 完了条件 + orchestrator 自身の検証とする。途中でゴールをずらさない。
- **worker の検証は安い段と重い段の 2 段**。task ファイルで名指ししたテストファイル 1 本を赤→緑で確認し、repo の lint・型チェック(無ければ変更ファイルへの lint・incremental typecheck)を必ず回す。これを安い段とし、完了報告前に 0 件にする。repo の検証が数分以内なら、task ファイルで指定した全体 test・E2E・build などの重い段も worker が回し、report にコマンド・真の exit code・ログのパスを残す。目安 5 分超の重い repo は orchestrator だけが回す。振る舞いが変わらないタスクではテストを名指ししないが、安い段は行う。
- **worker セッションは原則として新規起動**。初回タスクは新規 pane に投函する。同じ ticket の修正往復では、前の worker pane が生きていて文脈が健全なら同じ worker に修正 task を再投函してよい。誤った報告・堂々巡り・同じ指摘が 2 往復続くなど文脈が汚れた場合は新規起動へ戻す。再投函でも route manifest と courier は投函ごとに新規作成し、report / done マーカーはラウンドごとに分ける。新規 worker の場合も、必要な背景・前回レポート・指摘事項を task ファイルへ自己完結に書く。
- 新規起動するのは worker 側だけ。orchestrator(この skill を読んでいる側)は同じセッションを継続し、
  ゴール、レビュー結果、往復回数の文脈を保持する。
- **通信状態は投函ごとの `/tmp` route manifest を唯一の正本にする**。投函側だけが起動時の環境変数を使って自分の pane を検証し、
  `transport`、`origin`、`worker_role`、`worker_pane`、`reply_to`、`task_id`、`report_file` を新規 manifest へ固定する。
  manifest は投函側と courier 専用であり、環境変数、以前の task、会話、pane 番号のコピーから通信情報を再解釈しない。
  これにより同時並行のキャッチボールでも報告先が混ざらない。
- **「報告した/送信した」は `mark_report_done.sh` の出力どおりにしか言わない**。同スクリプトは done マーカー
  作成後、courier (`deliver_report.sh`) が書く配送 receipt (`<report>.delivered` / `<report>.undeliverable`) を
  最大 60 秒待って結果を出力してから終了する。tmux 転送は `tmux send-keys` の受理までしか汎用に確認できないため、
  courier は送信前後で宛先 pane の表示内容が変化したか(相手が処理を始めれば TUI の種類を問わず何かが変わる)
  を着弾の追加根拠とし、変化がなければ `confirmed=unconfirmed` の receipt を残す。Herdr は `herdr_send.sh` の
  着弾・処理開始確認をそのまま採用する。出力が「配送を確認できた」以外(未確認・配送失敗・60 秒タイムアウト)
  なら、worker はその文言をそのまま最終報告・依頼主への回答に反映し、自分の判断で「報告した/送信した」と
  言い切らない(送達コマンド成功だけを根拠にした「報告済み」は、依頼主が着弾を確認できないまま残る)。
- **配送未確認・通知欠落時は on-disk の成果物を直接読みに行く。完了済み worker pane へ再確認を求めない**。
  `confirmed=unconfirmed` でも report 自体と done マーカーは既に完成している(courier の送達コマンド自体は
  成功しており、着弾の表示変化だけを確認できていない)。orchestrator は自分が作った route manifest から
  `report_file` / `<report_file>.delivered` / `<report_file>.undeliverable` のパスを直接知っているので、
  `[報告]` 行や通知が来ないまま様子を見るときはこれらのファイルを直接読み、report が完成していれば
  Workflow 6 のレビューへそのまま進む。**同じ worker pane へ「届いたか」「もう一度送って」と聞き直さない**
  (`mark_report_done.sh` は同一 report パスの再実行を拒否するため worker は何もできず、ターンを消費して
  手詰まりの応答を返すだけになる)。report が未完成のときだけ `tmux capture-pane` で pane の状態を
  1 回覗いてから対応を決める。この確認を怠ると、report と worker 作業ツリーの未コミット diff が
  レビュー・コミットされないまま worker セッションが終了・放置され、孤立しかねない。
- **worker には宛先情報を一切渡さない**。manifest パス・transport・pane ID を task ファイルへ書かない。
  宛先情報を worker に握らせると、codex の automatic approval review が「task 由来の未検証な宛先へ workspace 由来の
  レポートを送信する」として報告コマンドを拒否する。また codex sandbox は tmux/herdr の
  unix socket へ connect できない(EPERM)。worker の報告義務は「report を書く → `mark_report_done.sh` で
  `<report>.done` マーカーを書く」というローカルなファイル書き込みだけにし、done マーカーの検知と実際の配送は
  投函側が `report_route.sh` で起動した courier (`deliver_report.sh`) が行う。
- **作業中の worker pane は orchestrator と同じウィンドウに見える形で置く**(ユーザーが作業の様子を見られるようにするため)。
  `ensure_worker_pane.sh` が分割して tiled で並べるので、その後に `tmux break-pane` / `new-window` で
  別ウィンドウへ移したり隠したりしない。手狭なら終わった worker の pane を閉じて場所を空ける。
- **報告済み worker pane は閉じる**。`[報告]` が着弾し、対応するレポートファイルを読めたら、その報告に
  含まれる worker pane id だけを閉じる。Herdr は `herdr pane close`、tmux は `tmux kill-pane` を使う。
  orchestrator 自身や、未報告・実行中の別 pane は閉じない。
- **worker はコミット禁止**。変更は作業ツリーに残させ、レビュー・検証・コミットは orchestrator が行う。
- **worker の再委譲は task ファイルの明示があるときだけ**。task ファイルを受け取った側は自分で実装する
  worker であり、既定では別の worker を起動して丸投げしない。入れ子は有用な場面もある(大きな task を
  分割して並列に回す等)ので禁止ではなく、orchestrator が task ファイルに「この部分は N 人の worker に
  分けて投函せよ」のように書いたときに限って行う。worker が自分の役割を取り違える典型は次の 3 つで、
  いずれも再委譲の根拠にならない:
  - 報告手順にこの skill の script パスが書かれている(報告 script の置き場所であって orchestrator 指名ではない)
  - リポジトリの AGENTS.md / CLAUDE.md に「実装は agent-orchestrate で worker へ委譲する」節がある
    (それは main = orchestrator 向けの規則。task を投函された側には適用しない)
  - 自分の instruction file に「実装は委譲する」方針がある(task 側の明示が優先する)
  task-template の役割宣言節はこの取り違えを先回りで潰すためのものなので必ず残す。無断の入れ子は同じ作業に
  worker が 1 段余計に挟まって時間とトークンを倍にし、report / receipt の対応も追いにくくする。
- **worker の質問経路はブロック報告に一本化する**。タスクファイルは投函時点で承認済みの設計であり、
  worker に対話での設計承認・小さな確認を求めさせない(task-template の「対話承認の禁止」節を必ず残す)。
  worker が pane 内で承認待ちになると、誰も見ていなければ永久に止まり、見ていればユーザーへ手間が流れる。
  本当に判断が必要な分岐は「質問と選択肢を report に書いてブロック報告」させ、orchestrator が回答を
  焼き込んだ次ラウンドのタスクで再投函する。ユーザーへ質問を運ぶのは、orchestrator 自身に裁定できない
  仕様決定だけ。
- **検証は記録で裏取りし、同じ入力では再実行しない**。orchestrator は worker の成功記録(コマンド・真の exit code・ログ)を確認する。記録が無い・矛盾する・ログが途切れる・入力が変わる場合だけ該当コマンドを再実行する(基準は Workflow 6)。
- **重い検証を往復ごとに課さない**。デプロイ・シミュレーション、E2E、フルビルドのような分単位の検証は、
  タスクの完了条件へ機械的に並べず、**その往復の変更が実際に触れた層にだけ**要求する。全往復へ課すと、
  失敗の反復を減らすために入れた検証が最大のボトルネックになり本末転倒になる。重い検証は最終段でまとめるか、対象層を触った往復だけに絞る。
- **往復は 10 回まで**。上限は無限キャッチボールを止めるための安全弁であり、指摘に沿って前進している
  往復を早く打ち切るためのものではない。各往復で前回の指摘が解消され、残る指摘が新しく狭いものになって
  いる限り、回数が重なっても修正依頼を続ける(例: 1 往復目で範囲外の書き換え、2 往復目でコメントの戻し
  漏れ、と指摘が変わりながら減っていく)。次のどちらかに当たったら回数に関係なく停止し、状況と残課題を
  ユーザーへ報告して指示を仰ぐ:
  - 10 回の修正依頼でゴールに達しない
  - 同じ指摘が 2 往復続けて解消されない、または直した所が次の往復で元に戻る(前進していない)
  ユーザーが上限の変更・撤廃を明示した場合はそれに従う。
- 大きいタスクは 1 往復に詰め込まず、検証可能な単位に分割して順に投函する。

## Workflow

### 1. ゴール設定

- ユーザーの依頼から完了条件を箇条書きで固める(例: 仕様 N 項目、変更ファイル一覧)。
- task ファイルで、repo の検証が数分以内か（軽い repo なら worker に重い段を指定、目安 5 分超なら orchestrator のみ）、安い段のコマンド、重い段のコマンドを指定する。
- 受入基準ごとに対応するテスト（ファイル:テスト名）を task に書く。UI task では URL と操作を指定する。
- 曖昧さが残るなら実装に入る前にユーザーへ確認する。

### 2. 自分のペイン確認と worker 起動

```sh
if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  self="$HERDR_PANE_ID"
  herdr pane get "$self" # Herdr の返信先を検証する
elif [[ -n "${TMUX_PANE:-}" ]]; then
  self="$TMUX_PANE"
  tmux display-message -p -t "$self" '#{pane_id}'
else
  echo "error: tmux でも Herdr でもないセッションでは orchestrator になれない" >&2
  exit 1
fi
echo "reply-to=$self"
```

- **前提チェック**: orchestrator は tmux か Herdr の pane 内で動いている必要がある。どちらでもない場合、`$TMUX_PANE` は
  空になり、返信先が空のまま manifest を作って全ての報告が黙って迷子になる。この分岐に落ちたら worker を起動せず停止し、
  tmux / Herdr 内でセッションを開き直すようユーザーへ依頼する。ポーリングや直接実装への切り替えで代替しない。
- Herdr 内では送信元が名前なし pane でも、**`$HERDR_PANE_ID` が返信先の正本**である。`herdr pane get "$self"` が成功した
  実値を使い、role は補助情報として扱う。`$TMUX_PANE` は Herdr を包む外側 tmux の pane であり、Herdr 内の agent 間の返信先には使わない。
- **worker role をタスクごとに選ぶ**。`implementer` (実装・修正)、`reviewer` (独立レビュー)、
  `investigator` (原因調査・再現)、`verifier` (テスト・受入確認) から、今回委譲する主目的に最も近いものを 1 つ選ぶ。
  仕様が固まった機械的な作業・原因まで分かっている修正は軽い worker（pi など）、状態・競合を含む UI、設計判断が残るもの、基盤やランタイムに絡むものは上位の worker（claude など）へ振る。基盤・ランタイム・外部サービスの挙動に不確かさがある ticket は、実装前に investigator で切り分ける。モデル名で手順は分岐させない。
  pi は、明示指定が無くても軽い実装の委譲先に選んでよい（既定の worker は codex のまま）。
  1 task の大きさは worker の力量で決める。上位の worker は必須テスト 5〜8 件程度、軽い worker は 2〜3 件程度を目安にし、大きい ticket は前半・後半（A・B1・B2a のように）に分けて順に投函する。worker が「未着手」や一部だけのブロックで返したら、同じ task を再投函せず、さらに小さく割って出し直す。モデルごとの実測の目安は [references/worker-calibration.md](references/worker-calibration.md)。依存しない ticket は `git worktree add` で作業ツリーを分けて worker を並行起動する。E2E のポートやローカル DB が衝突する repo では task に注意を書き、衝突する検証は orchestrator 側でまとめる。積み重ねた PR にせず、マージ順は orchestrator が決める。
  role は単なる表示名ではなく ID 照合・報告・cleanup のキーなので、曖昧な `worker` や固定の `implementer` を使わない。
- **worker agent は `codex` / `claude` / `pi` から選ぶ**。ユーザーが明示していればそれに従う。
  **明示がなければ既定は `codex`**。選択 UI で確認する場合も選択肢の一番上は `codex` にする
  (質問ツールを使う場合、先頭 = 既定 = `codex`)。
  一度選ばれた agent は同一セッションの以後の投函の既定にし、往復ごとに聞き直さない(ユーザーが
  変更を明示したときだけ切り替える)。agent 種別によって rule・完了条件・レビュー基準は変えない
  (モデル名で orchestrator 側の手順を分岐させないのと同じ)。
- `ensure_worker_pane.sh` は agent を通常の承認・sandbox 設定のまま起動する(役割は task ファイルの役割宣言で渡す)。
  worker は、この script 経由で起動する(準備完了の確認と pane の並べ方を揃えるため)。
- worker 専用の起動オプション(`codex -p worker` など)を使うなら、設定ファイル `${AGENT_ORCHESTRATE_WORKERS:-~/.config/agent-orchestrate/workers.sh}` で `agent_invocation`(起動コマンドの配列)を `$agent` ごとに差し替える。script がこのファイルを source する。
- **初回タスクは新しい worker ペインを開いて起動する**。同じ ticket の修正往復で健全な pane を続投する場合はその pane を使い、文脈が汚れた場合だけ次のコマンドで新規起動する:

```sh
worker_agent=<codex|claude|pi>
worker_role=<implementer|reviewer|investigator|verifier>
worker=$(bash <skill-dir>/scripts/ensure_worker_pane.sh "$worker_agent" <対象リポジトリの絶対パス> "$worker_role")
```

- Herdr 内の上記コマンドは同梱の `scripts/herdr_start_agent.sh "$worker_role" -- "$worker_agent" ...` を実行する。この script(`herdr agent start` を包む。`herdr`・`jq` が要る)は対象 repo の
  Herdr workspace を再利用し、対話 zsh で端末初期化を完了させてから agent を起動する。起動後に
  `herdr agent start` の起動結果に含まれる `pane_id` を `$worker` として取得する。role 名からの再検索は古い
  agent 登録を拾いうるため行わない。これで
  投げる側と投げられる側が同じ `<worker-role>` / `wN:pN` を把握する。tmux 内では従来どおり新規 pane を起動する。
- task の slug ごとに `route_dir=$(mktemp -d /tmp/<slug>-route.XXXXXX)` を作り、`route_file="$route_dir/route"` とする。次に task / report パスを含めて
  `bash <skill-dir>/scripts/report_route.sh <route-file> <task-id> <report-file> "$worker_role" "$worker"`
  を実行する。script が環境から取得・検証した値を manifest へ固定し、`<report-file>.done` マーカーを監視する
  courier を起動する。tmux transport では courier を tmux server の `run-shell -b` で起動し、投函コマンドの
  shell が終了した後も worker の完了まで待てるようにする。`nohup` / `disown` だけでは agent tool が終了時に
  子プロセスを回収する環境で courier が先に落ちることがある。task へ記入するのは **report ファイルのパスと done マーカー手順だけ**。manifest パス・
  `transport` / pane ID を task へ手入力・複写しない。
- 新規起動直後はテーマ選択や(claude の)フォルダ信頼確認などの初回ダイアログが出ることがある。
  `ensure_worker_pane.sh` は Herdr・tmux のどちらでも agent ごとの準備完了マーカー(codex: 入力欄の `›` プロンプト、
  claude: ステータス行の `Ctx:` 表示、
  pi: ステータス行の `(auto)` 表示)を確認してから worker ID を返す。投函側もその完了を待ち、起動直後の
  `idle` だけを根拠に task を送らない。tmux では念のため**投函直前にもう一度 until ループで確認する**
  (1 回の capture では不十分。起動バナー表示中の投函は丸ごと飲まれる):

```sh
for i in $(seq 1 30); do
  snap=$(tmux capture-pane -p -t "$worker")
  if grep -qE "loading|Initializing|MCP startup" <<<"$snap"; then sleep 2; continue; fi
  grep -qE "›|Ctx:|Ask anything|\(auto\)" <<<"$snap" && break   # agent ごとの入力プロンプト
  sleep 2
done
```
  claude worker がそのリポジトリで初回起動の場合、この確認でフォルダ信頼確認ダイアログが見つかることが
  ある。対処は Gotchas の該当項目を参照。
- `ensure_worker_pane.sh` はどの agent も通常の承認・sandbox 設定で起動する。準備完了マーカーが確認できない
  (=未知の初回ダイアログや承認待ちで止まっている可能性がある)場合はタイムアウトしてエラー終了する。
  自動で迂回せず、pane を確認してユーザーに対応を仰ぐ。

### 3. タスクファイル作成

- `/tmp/<slug>-task.md` に [references/task-template.md](references/task-template.md) の形式で書く。
- タスクファイルは、新規 worker がこのファイルだけで作業できるよう自己完結させる。修正依頼では、
  前回レポートのパス、レビューで落とした理由、期待する修正結果を必ず含める。
- 必須要素: 対象リポジトリ、前提コンテキスト、仕様(完了条件)、リポジトリ固有の注意、名指しコマンド以外を実行しない指示、
  **報告手順(report ファイルの絶対パスと、`bash mark_report_done.sh <report-file> <完了|ブロック> <1行要約>` による done マーカー作成。完全な例は [task-template.md](references/task-template.md) を参照)**、コミット禁止、役割宣言(worker 自身が実装する旨。分割投函させたいときはその範囲を明示)。
  manifest パス・pane ID・transport は書かない。
- 軽い worker ほど、判断の余地を task 側で潰す。写すファイル・API の形・テスト名を名指しし、テストの組み方が自明でないとき
  （偽の LLM・外部 API の stub など）は、使う部品とコードの例を task に書く。例が無いと、実装だけ入れてテストを書かずに返しやすい。
- worker の sandbox から届かない前提作業は、投函前に orchestrator が済ませる。依存の install（registry への通信、pnpm の
  `allowBuilds` のような build スクリプトの許可）、ブランチ・worktree の作成がこれに当たる。worker が自分で回避を試みて止まるのを防ぐ。

### 4. 投函

- [references/delivery.md](references/delivery.md) の手順で worker ペインへ 1 行メッセージを送る:

```
/tmp/<slug>-task.md を読んで、その指示どおり作業してください。完了・ブロック時の報告手順もそのファイルにあります。
```

- Herdr worker が投函前に `idle` なら、`herdr_send.sh` の成功出力だけで完了扱いにせず、`herdr pane get "$worker"` で
  `agent_status=working` への遷移を確認する。本文が画面に見えるだけでは、入力欄に残った未送信の task を検出できない。
  遷移しない場合は `herdr_send.sh` が Enter だけを 1 回再送する。それでも確認できなければ投函失敗として停止し、
  「worker に委譲した」とは報告しない。
- tmux worker では `tmux_send.sh` の正常終了は「tmux server が受け付けた」ことしか保証しない。**task 投函では
  Working 遷移の確認までを投函完了条件とする**(起動直後の再描画で本文が飲まれることがある):
  送信後、`tmux capture-pane` で `Working` / `esc to interrupt` 等の実行中表示への遷移を最大 20 秒待つ。
  遷移しなければ ENTER を 1 回だけ再送。それでも遷移せず**入力欄が空(プレースホルダー表示)** なら、本文が
  丸ごと落ちたケースなので本文を 1 回だけ再送してよい(空の入力欄への再送は二重投函にならない。入力欄に
  本文が残っている場合は ENTER 再送のみ)。それでも遷移しなければ投函失敗として停止し、「worker に委譲した」
  とは報告しない。キャッチボール全体の end-to-end 確認は、courier による `[報告]` の着弾で行う。
- **必須経路は courier**。orchestrator も worker も任意の CLI エージェント(claude / codex /
  その他)で、入れ子の委譲も起こりうる。courier(`report_route.sh` / `deliver_report.sh`)と送信 script に
  よる `[報告]` 着弾は、ホスト CLI の機能に依存せず成立する唯一の経路なので、常に起動する。
- **任意の追加パス**: ホスト CLI の Bash 相当ツールが「バックグラウンド実行した処理の完了で通知が届き、
  ターンが自動再開される」契約を**ツール自身の説明文で明記している**場合に限り、投函と同じターンで
  `bash <skill-dir>/scripts/wait_for_report.sh --i-confirmed-run-in-background-auto-resumes-my-turn /tmp/<slug>-report.md`
  をその契約の機能で起動しておける(例: Claude Code の Bash tool は `run_in_background: true` で起動した
  コマンドの完了を task notification として届け、ターンを自動再開する)。`report_file.done` の出現を
  キー入力なしで知れる。通知には script の出力行 `worker完了検知: status=... summary=... delivery=... report=<path>` が
  含まれるので、並行投函や修正ラウンドが重なっていても `report=` のパスでどのタスクの完了かを識別する
  (推測で決めない)。この契約を確認できないなら使わない。シェルの `&` は代用にならず通知は来ない(スクリプト自身が確認フラグを
  必須にしているのはこのため)。追加パスを使っても courier の起動は省略しない。並行投函の混戦防止(route
  manifest)、契約を持たないホスト向けの経路、配送記録(receipt)は courier の役割のままであり、追加パスは
  「worker 完了を早く知る」冗長手段に限定する。

### 5. 待機(=ターン終了)

- 投函したら「worker に委譲した。報告が着弾したらレビューする」とユーザーへ伝えてターンを終える。
- 報告の着弾は 2 経路のどちらかで気づく。どちらが先に来ても Workflow 6 のレビュー手順は同じ:
  - courier が送信 script で打ち込む `[報告] ...` 行が起動元 pane に届く(**どの
    CLI エージェントが orchestrator でも有効な唯一の必須経路**)。
  - `wait_for_report.sh` を起動していれば、`report_file.done` の出現でバックグラウンドタスク完了通知が届く
    (自動ターン再開の契約を確認できたホストでのみ有効。この通知が先に来た場合は `[報告]` 行の着弾を待たず、
    report ファイルを直接読んでレビューへ進んでよい。worker pane は Workflow 2 で確保した `$worker` 変数を
    そのまま使う)。
- 報告が来ないままユーザーに「様子を見て」と言われたときは、まず `report_file` /
  `<report_file>.delivered` / `<report_file>.undeliverable` を直接読む(PRIMARY RULES
  「配送未確認・通知欠落時は on-disk の成果物を直接読みに行く」参照)。report が完成していれば
  worker pane へは触らず Workflow 6 のレビューへ進む。report が未完成のときだけ
  `tmux capture-pane -p -t <worker>` で 1 回だけ状況を覗く(これは単発確認でありポーリングではない)。
- **pi worker の返答経路も同じ**。pi の通常の最終回答は pi worker pane の中だけに表示され、自動では起動元へ転送されない。
  起動元 pane に届くのは、worker が report を書いて `mark_report_done.sh` を実行した後に courier が投入する
  `[報告]` メッセージである。これは起動元 pane への入力であり、orchestrator を動かしている CLI 自体が
  pane の入力を自動で会話イベントとして取り込むとは限らない。worker の最終回答が見えないことだけでは
  異常と判断せず、報告が届かない場合は route manifest の `report_file` を使って report と配送 receipt を確認する。

### 6. レビュー

- レビューの最初に `bash <skill-dir>/scripts/check_delivery.sh <repo> <task-file> <base-commit>` を実行する。`check_delivery: status=fail` なら diff を読まずに差し戻し、出力をそのまま修正 task に貼る。pass のときだけ以下のレビューへ進む。
- `[報告]` 行の着弾で気づいた場合: 行、route manifest、レポートファイルを読む。manifest の `task_id` /
  `worker_pane` / `report_file` と一致しない報告は別のキャッチボールのものとして扱い、worker を閉じない。
  Herdr 宛ての報告は `herdr_send.sh` が Herdr pane へ直接入力するため、外側 tmux pane の scrollback ではなく
  この会話への着弾を正とする。`[報告]` 行の `worker=<role>/<pane-id>` が今回投函した worker と一致し、
  レポートファイルを読めたら、その worker pane を閉じる。自分の pane と一致する場合、pane id が報告に
  無い場合、まだレポートを読めていない場合は閉じない。
- `wait_for_report.sh` の完了通知で気づいた場合: `$worker`(Workflow 2 で確保した pane ID)をそのまま使って
  閉じてよい。`[報告]` 行を待つ必要はない。通知の `delivery=` が courier の配送結果で、`delivered` 以外
  (`undeliverable` / `unconfirmed` / `pending`)なら `[報告]` は届いていない。report を直接読んでレビューへ進み、
  ユーザーへの報告に「この worker の `[報告]` は配送できなかった」と書く(courier log と report 末尾の
  「報告配送」節に失敗時の起動元 pane の状態が残る)。receipt (`<report>.delivered` / `.undeliverable`) は
  他の pane からもこのキャッチボールの状況を追えるよう消さない。
- Workflow 5 の on-disk 直接確認(`[報告]` 行も通知も来ないまま report ファイルを直接読んで気づいた場合):
  `$worker`(Workflow 2 で確保した pane ID)をそのまま使って閉じてよい。ただし pane を閉じても worker が
  書いた作業ツリーの diff は消えずそのまま残るので、この diff を精読・コミットする前提で必ず後続の
  レビュー手順(report/ログの退避、`git status` / `git diff` 精読、コミット)を続けて行う。
  ここで止めて放置すると、配送未確認だったこの diff は誰にもレビューされないまま孤立しかねない。

```sh
reported_worker='<[報告] 行の worker=<worker-role>/wN:pN または worker=%NN から pane ID を転記>'
worker="${worker:-$reported_worker}"
if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  [[ "$worker" != "$HERDR_PANE_ID" ]] && herdr pane close "$worker"
elif [[ -n "${worker:-}" && "$worker" != "${TMUX_PANE:-}" ]]; then
  tmux kill-pane -t "$worker" || true
fi
```

- **報告を読んだら、まずエビデンスを退避する**。`/tmp` はセッション境界やモデル切り替えで丸ごと
  消えることがあり、report と検証ログが消えると裏取りの根拠が失われる。
  worker の書き込み先は sandbox の制約で `/tmp` のままにし、着弾直後に orchestrator が退避する:

```sh
slug=<slug>
keep=~/.local/state/agent-orchestrate/"$slug"
mkdir -p "$keep" && cp -f /tmp/"$slug"*-report.md /tmp/"$slug"*.log /tmp/"$slug"-task.md "$keep"/ 2>/dev/null
```

  長い調査計画など複数ラウンドで参照する成果物も同じ場所へ退避し、以後は退避先を参照する。
- `git status` / `git diff` で変更を精読する。仕様との照合、参照残り、トークン・命名の妥当性まで見る。
- まず report に受入基準ごとのテスト対応表（ファイル:テスト名）があることを確認する。表が無ければ検証せずに差し戻す。UI task では指定場面のスクリーンショットと画像パスがあることを確認し、orchestrator が画像を見る。
- 検証は worker が安い段と、軽い repo なら重い段も行う。変更が触れた層に応じて、repo の検証コマンド(repo の AGENTS.md などに書かれた typecheck / test / lint 等)の成功記録を確認する。目安 5 分超の重い repo は orchestrator がここで実行する。記録を採用する条件:
  1. 記録にコマンドと真の exit code がある
  2. 対応するログファイルが実在し、末尾がその task の
     正常完了サマリ(テスト集計・build 完了行など)と矛盾しない
  3. 記録の時刻がこの往復の作業時間帯と整合する
  4. 記録以降に検証入力が変わっていない(レビュー中の diff 精読は入力を変えない)
- **再実行するのは次の場合だけ**: 成功記録が無い / 記録とログが矛盾する / ログが途中で途切れている /
  レビューでコードに手を入れた後 / 実行順・環境依存のフレークを疑う具体的根拠がある。再実行はまず該当
  1 task に絞り、全量再実行は実際に矛盾が見つかったときだけ行う。worker が task ファイルの名指しで部分 suite を回していた場合も、その report を成功の根拠にはせず、ここで検証コマンドの記録を確認する。worker が「既存の失敗」「環境の問題」と書く場合は、修正前 commit の同じ失敗ログが無ければ差し戻す。
- **合否は真の exit code で判定する**。`cmd | grep 'fail' | ...` のようなパイプ要約は、パイプで
  exit code が差し替わるうえ、テストランナーの外側で起きる失敗(script 内の `cd` 失敗、
  ランナー自体の異常終了)がパターンに現れず「全緑」に見える。
  `cmd > log 2>&1; echo exit=$?` で exit code を先に確定し、ログの grep は内訳の把握にだけ使う。

### 7. 判定

- **合格**: 仕上げ(コミット、push、ユーザーへの最終報告)。コミットはリポジトリの規約に従う。
- **不合格**: 指摘を箇条書きにした修正タスクファイル `/tmp/<slug>-fix-<N>.md` を作り、2 へ戻って
  前の worker を続投できない場合は、新しい worker セッションを起動して投函する。
  修正ラウンドのレポートは `/tmp/<slug>-fix-<N>-report.md`、報告メッセージは `[報告] <slug> fix-<N> ...`
  とラウンドを含めさせる(前回レポートの上書き防止と、どの往復への返答かの識別のため)。
  往復カウントを 1 増やし、PRIMARY RULES「往復は 10 回まで」の停止条件に当たったら停止してユーザーへエスカレーションする。

### 8. 積み重ねた PR のマージ

依存する PR がある base のブランチを `--delete-branch` で先に消すと、GitHub は依存する PR の base を付け替えず閉じる。積み重ねた PR は、次の PR の base を先に main へ変えてからマージし、ブランチ削除は最後にまとめる。マージの権限が与えられているときは、orchestrator が自分で判断して行い、ユーザーにマージを頼まない。

### 9. 最終報告

- ユーザーへ: 達成したゴール、変更概要、検証結果、往復回数、残課題(あれば)。

## Gotchas

- worker が dev server や workerd を止め忘れて、ポート（例 5173）を握ったまま pane を閉じることがある。レビューで実機確認の前に
  `lsof -nP -iTCP:<port> -sTCP:LISTEN` で持ち主を確かめ、今回の worker が起動したものなら止める。task にも「撮影の後に dev server を止める」と書く。

- worker は原則新規起動だが、同じ ticket の修正往復では健全な pane へ再投函できる。起動時の skill 一覧しか知らないことがある。worker が直接呼ぶのは
  `mark_report_done.sh` のみ(tmux/herdr の送信スクリプトは投函側の courier が使う)なので、タスクファイルには
  **`mark_report_done.sh` の絶対パスと report ファイルの絶対パス**を明記する。
- 報告メッセージは「どのタスクの報告か」を識別できるよう、必ずタスク名(slug)を含めさせる。Herdr では
  `origin=<pane-id>` と `worker=<role>/<pane-id>`、tmux では `origin=<pane-id>` と `worker=<pane-id>` を必ず含める。
- worker が報告ファイルだけ書いて `mark_report_done.sh` の実行を忘れると着弾しない。タスクファイルの報告手順は
  「ブロック時も必ず報告」「done マーカー作成が完了条件の一部」と明記する。
- pi を含め、worker の最終回答を pane 間で中継する機能には依存しない。報告が起動元 pane に見当たらない場合は
  worker の応答を待ち直したり pane から転記したりせず、manifest の `report_file` とその `.done` /
  `.delivered` / `.undeliverable`、および `route_file.courier.log` を確認する。
  `.done` が無ければ worker が報告処理まで完了していない。receipt が `confirmed=unconfirmed` なら送信コマンドは
  成功しているが着弾未確認なので、report を読み Workflow 6 へ進む。`.undeliverable` または courier log のエラーなら
  配送失敗として扱い、宛先を推測して再送しない。
- 宛先 pane が途中で消えた配送不能は、実装上の `ブロック` ではない。配送と配送不能の記録は courier
  (`deliver_report.sh`) が行う。`mark_report_done.sh` は done マーカーを書いた後、courier の配送 receipt を
  最大 60 秒待ってから終了する(受け取れなければ非 0 で終了する)。同じ report パスで再実行すると
  「記録済み」エラー(exit 1)になるので、タイムアウト後もマーカーの再作成はできない。worker は宛先を
  role や環境変数から推測しない。
- worker pane は報告後に閉じるため、あとで pane scrollback に頼らない。必要な事実は必ず report ファイルへ書かせる。
- `/tmp` の成果物は永続しない。セッションをまたぐ計画・レポート・検証ログは Workflow 6 の手順で
  `~/.local/state/agent-orchestrate/<slug>/` へ退避しておく。退避を怠ると、次ラウンドの worker が
  「必読の計画ファイルが無い」でブロックしたり、裏取り不能で全量再実行になる。
- `HERDR_PANE_ID` / `TMUX_PANE` は投函側が manifest を生成する瞬間のローカル検証専用であり、task / worker / 報告の受け渡しに使わない。
- 会話の再開(compaction)の後、Claude Code の Bash から `TMUX_PANE` が空になることがある。空のまま `tmux split-window -t "$TMUX_PANE"` すると、
  `-t ""` が別セッションのアクティブな pane を分割し、worker がユーザーの別の作業のウィンドウに出た(`tmux join-pane -h -s <worker> -t <自分>` で戻した)。
  `report_route.sh` も `TMUX_PANE is not available` で止まる。最初の投函で確かめた自分の pane id を控えておき、再開後は
  `tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index} #{pane_title}'` で生きていることを確かめてから、分割先と
  `TMUX_PANE=<自分の pane id> bash report_route.sh ...` に明示する。分からなければ分割しない。
- courier は macOS 標準 Bash 3.2 と WSL Bash 5 の両方で動かす。スクリプトは Bash 3.2 互換を保ち、連想配列など Bash 4 以降の構文を使わない(Bash 3.2 では配送開始前に構文エラーで終了し、報告が届かない)。
- codex sandbox(`workspace-write` でも)は unix socket への connect を遮断するため、tmux も herdr も直接
  叩くと EPERM になる。claude / pi の既定 sandbox でも同様に遮断される前提で扱い、
  agent の種類にかかわらず worker から tmux/herdr を直接叩く手順を task に書かない。一方 host の `/tmp` は
  いずれの sandbox からも読み書きできるため、報告は必ず `mark_report_done.sh`(done マーカー経由)を使わせる。
- codex / claude はそれぞれ自前の plan の手順に従い「実装前の設計承認」を pane 内の対話で
  求めて止まることがある。task-template の
  「対話承認の禁止」節が先回りの対策であり、agent の種類によらず必ず残す。それでも承認待ちで止まった
  場合に限り、orchestrator が同じ pane へ 1 回だけ承認/裁定を送って再開させる(これは中断済み worker の
  再開であり、新規タスクの追投函ではない)。
  ユーザーには運ばない。
- claude worker は、そのリポジトリで初めて起動したときに「フォルダを信頼するか」の確認ダイアログで
  止まることがある。`ensure_worker_pane.sh` の準備完了マーカー(`Ctx:`)はこのダイアログ
  では出ないため、tmux 経路・Herdr 経路のどちらでも自動では突破せず待機タイムアウトへ落ちる。task を送る前に
  `tmux capture-pane -p -t "$worker" | tail -15`(Herdr は `herdr pane read`)でこのダイアログが出ていないか
  確認し、出ていたら orchestrator が 1 回だけ `Enter`(既定選択の「1. Yes, I trust this folder」)を送って
  解消してから task を投函する。これは初回起動時の環境確認であり、task 実行中の設計承認とは別物なので、
  同じ pane への 1 回限りの介入として扱ってよい。
- codex worker も同様に、そのリポジトリで初めて起動したときに **「ディレクトリ信頼」と「hooks 信頼」の
  2 段**の確認ダイアログで止まることがある。claude と違い 2 回応答が要るため、1 回
  `Enter` を送っただけでは 2 段目で止まったままになる。この状態で task を投函すると本文が丸ごと吸われ、
  worker が何もせずに終了する。準備完了マーカー(`›` プロンプト)が出るまで `tmux capture-pane` で確認し、
  ダイアログが出ていたら**残っている段の数だけ**応答してから投函する。既に同じリポジトリで codex を
  起動したことがあるセッションでは出ない(1 段目で `ensure_worker_pane.sh`
  の準備完了判定が通り、ダイアログに遭遇しないこともある)ため、「前回出なかったから今回も出ない」と
  仮定せず毎回確認する。
- pi を 1 window に 3 台以上続けて `ensure_worker_pane.sh` で起動すると、3 台目以降の pane 幅が 10 桁ほどに縮み、準備完了
  マーカー `(auto)` が画面に収まらず 30 秒で「起動しなかった」になる（pi 自体は起動している。2026-09-14 実測）。
  `tmux select-layout -t <session:window> tiled` で全 pane を均等にしてから `capture-pane` で `(auto)` を見直す。
  5 台並列でも pane が 69x16 あれば動いた。
- 並行の worker に E2E（実サーバーを起動するテスト）を同時に回させない。ファイルが重ならないことは安全の条件にならない。
  dev サーバーは作業ツリー全体を読むので、別 worker の書きかけのコードで無関係に落ちる（ある repo で 2 回落ちて
  緑を確認できなかった）。E2E は直列にするか、worktree ごとに E2E のポートも分ける。worktree を分けても Playwright の
  `reuseExistingServer` が固定ポートを取り合い、他の worktree のサーバーに当たる。
