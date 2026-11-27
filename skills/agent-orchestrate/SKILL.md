---
name: agent-orchestrate
description: "tmux または Herdr の pane で動く worker(codex / claude / pi)へ実装を任せ、完了報告のレビューと再依頼を繰り返してゴールまで進めるときに使う。pane で動くエージェントへメッセージを確実に届ける手順(transport の選び方、Enter を分けて送る、着弾の確認、時刻を指定した送信)も持つ。「オーケストレーションモードで」と明示されたら、以降のセッションでは通常のタスクを毎回 worker へ任せるモードに入る。「ペインに送って」「codex に報告して」「Claude に完了を伝えて」「4 時に codex に Enter を送って」のような依頼でも使う。in-process の subagent(Agent tool など)とは別物で、pane worker への委譲と pane への送信を扱う。"
---

# agent-orchestrate

## 用途ごとの入口

- worker に実装を任せ、レビューと再依頼を繰り返す: このファイルを通して読む。
- pane へ 1 行を送るだけ(「ペインに送って」「codex に報告して」など): [references/delivery.md](references/delivery.md) だけを読む。
- 決まった時刻に送る(「4 時に codex に Enter を送って」など): [references/schedule.md](references/schedule.md) を読む。
- 報告が届かない、worker が止まった・起動しない: [references/troubleshooting.md](references/troubleshooting.md) を読む。

`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パスを指す。

## GOAL

orchestrator(この skill を読んでいるエージェント)と、tmux または Herdr の pane で動く worker が、
「タスクを渡す → 実装する → 報告する → レビューする → 直しを頼む → …」を繰り返し、最初に決めたゴールに届くまで続ける。

1 往復の流れ(例: orchestrator は claude `%4` / Herdr の `w1:p1`、worker は codex `%0` / Herdr の `w2:p1`):

1. orchestrator: ゴールを決め、task ファイルを書く。
2. orchestrator: worker の pane へ task を投函し、ターンを終えて待つ。
3. worker: 実装し、検証する。
4. worker: report を書き、`mark_report_done.sh` で done マーカーを置く。
5. courier: done マーカーを見つけ、orchestrator の pane へ `[報告]` 行を送る。
6. orchestrator: レビューする(diff の精読と、検証の記録の照合)。
7. orchestrator: 合格なら仕上げる。不合格なら 2 へ戻る。

## オーケストレーターモード(セッションを通した役割分担)

ユーザーが「オーケストレーションモードで」「オーケストレーターになって」「Opus をオーケストレーターにして」のように
**明示したときだけ**入る。明示のない通常の依頼では入らない。task ファイルを受け取って worker として起動したセッションも入らない。

- **モデルによって変えない**。この skill を読んでいるセッションが、どのモデルでもそのまま orchestrator になる。
  モデル名が違っても入り方の呼び名が違うだけで、手順・rule・完了条件は同じ。モデル名で手順を分けない。
- モードに入る前に、Workflow の「2. 自分のペイン確認と worker 起動」の前提チェック(tmux か Herdr の中にいるか)を通す。通らないセッションはモードに入れない。
  別の手段に勝手に切り替えず、tmux / Herdr の中で起動し直すようユーザーに頼んで止まる。
- モードの間は、調査・実装・検証などの通常のタスクを、そのつど指示がなくても毎回この skill で worker(codex / claude / pi)へ任せる。
- orchestrator が自分でやるのは、ゴール設定、task ファイルの作成、レビュー、検証、判定、commit、ユーザーへの最終報告。
  ただし、差し戻すより自分で直す方が速く、判断の要らない機械的な直しは自分でやってよい。目安は、10 行程度までの lint・format・型の直し、
  テスト 1〜2 本の補い、規約合わせ。判断が残る直し、振る舞いを変える直し、同じ種類の直しの繰り返しは worker に差し戻し、
  直し方を task ファイルに書く。自分で直した内容は commit の本文に書く。
- 組み合わせの例:
  - 実装: `implementer` に任せる → orchestrator が diff を精読し、検証の記録と照らしてレビューする
  - 原因調査: `investigator` に任せる → orchestrator が仮説を疑ってかかってレビューする → 修正は新しい `implementer` に投函する
  - 大きめの変更: `implementer` → 独立した `reviewer` でもう 1 往復 → orchestrator が最終判定する
  - 受け入れの確認だけ: `verifier` に任せる → orchestrator が結果を裏取りして報告する
- モードを抜けるのは、ユーザーが明示したとき(「オーケストレーションモード終了」など)。

## PRIMARY RULES

破ってはいけない条件だけを置く。手順の細部は Workflow にある。

- **ポーリングしない**。sentinel ファイルを見張るループや sleep のループを張らない(トークンを際限なく使う)。task を投函したらターンを終え、
  報告が届くのを待つ。そのため、task には完了時・ブロック時の報告義務を必ず書く。
- **任せる先は tmux / Herdr の pane worker だけ**。in-process の sub-agent(Claude Code の Agent / Task / Workflow tool など)は使わない。
  報告の経路(route manifest・courier・done マーカー)は pane worker が前提で、in-process では新しいセッションでの起動、
  報告の着弾をきっかけに動くこと、pane の片付けのどれも成り立たない。
- **ゴールは最初に固定する**。完了条件を task ファイルに書き出し、レビューの合格条件は完了条件に orchestrator 自身の検証を足したものとする。途中で動かさない。
- **通信先は、投函ごとの `/tmp` の route manifest だけを正本にする**。環境変数、前の task、会話、pane 番号の写しから通信先を読み直さない。
  こうしておけば、同時に何本やりとりしていても報告先が混ざらない。
- **worker に宛先の情報を渡さない**。manifest のパス、transport、pane ID を task に書かない。宛先を持たせると、codex の automatic approval review が
  「task 由来の確かめていない宛先へ、workspace 由来の report を送る」とみなして報告のコマンドを拒否する。worker の報告義務は、
  report を書いて `mark_report_done.sh` で done マーカーを置くことだけにする。
- **「報告した」「送信した」は、`mark_report_done.sh` の出力のとおりにしか言わない**。出力が「配送を確認できた」以外なら、その文言をそのまま書く。
- **配送を確認できないときや通知が来ないときは、ディスク上の report を直接読む。完了した worker の pane には聞き直さない**。
  `mark_report_done.sh` は同じ report のパスでの再実行を拒むので、聞き直しても worker にはできることがなく、ターンを使うだけになる。
  手順は Workflow 5。
- **worker は commit しない**。変更は作業ツリーに残させ、レビュー・検証・commit は orchestrator が行う。
- **worker は自分で実装し、ほかの worker へ任せ直さない(再委譲しない)**。例外は、orchestrator が task ファイルに「この部分は N 人の worker に
  分けて投函する」のように明示したときだけ。取り違えを防ぐ文面は task-template の役割宣言の節が正本なので、必ず残す。
- **worker からの質問は、ブロック報告の 1 本にまとめる**。task ファイルは投函した時点で承認済みの設計なので、pane の中で承認や確認を求めさせない
  (task-template の「対話承認の禁止」節を必ず残す)。答えは orchestrator が決めて次のラウンドの task に書き、ユーザーには orchestrator が決められない仕様の判断だけを回す。
- **検証は記録で裏取りし、入力が同じなら回し直さない。重い検証は、その往復で触った層にだけ求める**。基準は Workflow 1 と 6。
- **往復は 10 回まで**。前に進んでいる往復を早く打ち切るための上限ではない。止まる条件は Workflow 7。
- **作業中の worker の pane は、orchestrator と同じウィンドウに見えるように置き、報告を済ませた worker の pane は閉じる**。
  orchestrator 自身の pane や、まだ報告していない・実行中の pane は閉じない。

## Workflow

### 1. ゴール設定

- ユーザーの依頼から、完了条件を箇条書きで固める(例: 仕様 N 項目、変更ファイルの一覧)。
- 受け入れ基準ごとに、対応するテスト(ファイル:テスト名)を決める。UI の task では URL と操作を決める。
- **検証の 2 段を決める**(この節が正本。worker 向けの文面は task-template にある)。
  - 安い段: task で名指ししたテストファイル 1 本が赤から緑になるのを確かめ、repo の lint・型チェックを回す
    (repo に無ければ、変更ファイルへの lint と incremental typecheck)。worker が必ず回し、指摘は完了報告の前に 0 件にする。
    振る舞いが変わらない task ではテストを名指ししないが、安い段は回す。
  - 重い段(全体の test・E2E・build など): repo の検証が数分以内で終わる軽い repo なら worker が回し、コマンド・真の exit code・ログのパスを report に残す。
    目安として 5 分を超える重い repo では、orchestrator だけが回す。
  - デプロイ、シミュレーション、E2E、フルビルドのような分単位の検証は、task の完了条件に機械的に並べず、その往復の変更が実際に触った層にだけ求める。
    全往復に課すと、失敗の繰り返しを減らすために入れた検証がいちばんのボトルネックになる。重い検証は最後にまとめるか、その層を触った往復だけに絞る。
- 大きい task は 1 往復に詰め込まず、検証できる単位に分けて順に投函する。
- 曖昧なところが残るなら、実装に入る前にユーザーに確かめる。

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

- **前提チェック**: orchestrator は tmux か Herdr の pane の中で動いている必要がある。どちらでもないと `$TMUX_PANE` が空になり、
  返信先が空の manifest ができて、報告がすべて黙って迷子になる。この分岐に落ちたら worker を起動せずに止まり、
  tmux / Herdr の中でセッションを開き直すようユーザーに頼む。ポーリングや自分での実装に切り替えて代わりにしない。
- Herdr の中では、送り手が名前のない pane でも、**`$HERDR_PANE_ID` が返信先の正本**になる。`herdr pane get "$self"` が成功した値を使い、
  role は補助の情報として扱う。`$TMUX_PANE` は Herdr を包む外側の tmux の pane なので、Herdr の中のエージェント同士の返信先には使わない。
- **会話を再開(compaction)したあとは、自分の pane id を確かめ直す**。Claude Code の Bash から見た `TMUX_PANE` が空になることがある。
  空のまま `tmux split-window -t "$TMUX_PANE"` すると、`-t ""` が別のセッションのアクティブな pane を分割し、worker がユーザーの別の作業のウィンドウに出てしまう
  (出てしまったら `tmux join-pane -h -s <worker> -t <自分>` で戻す)。`report_route.sh` も `TMUX_PANE is not available` で止まる。
  最初の投函で確かめた自分の pane id を控えておき、再開したあとは `tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index} #{pane_title}'` で
  まだ生きているかを確かめてから、分割先と `TMUX_PANE=<自分の pane id> bash report_route.sh ...` に明示する。分からなければ分割しない。
- **worker の role は task ごとに選ぶ**。`implementer`(実装・修正)、`reviewer`(独立したレビュー)、
  `investigator`(原因の調査・再現)、`verifier`(テスト・受け入れの確認)のうち、今回任せる主な目的にいちばん近いものを 1 つ選ぶ。
  role はただの表示名ではなく、ID の照合・報告・片付けのキーなので、曖昧な `worker` や、いつも同じ `implementer` を使わない。
- **worker の agent は `codex` / `claude` / `pi` から選ぶ**。ユーザーが明示していればそれに従う。
  **明示がなければ既定は `codex`**。選択 UI で確かめる場合も、いちばん上の選択肢を `codex` にする(質問ツールを使うなら、先頭 = 既定 = `codex`)。
  一度選んだ agent は、同じセッションの以後の投函でも既定にし、往復のたびに聞き直さない(ユーザーが変更を明示したときだけ切り替える)。
  pi は、明示されていなくても軽い実装の任せ先に選んでよい。
- **task の性質で worker の格を選ぶ**。
  - 軽い worker(pi など): 仕様が固まった機械的な作業、原因まで分かっている修正
  - 上位の worker(claude など): 状態や競合を含む UI、設計の判断が残るもの、基盤やランタイムに絡むもの

  基盤・ランタイム・外部サービスの挙動に不確かさがある ticket は、実装の前に investigator で切り分ける。
- **agent の種類やモデル名で、rule・完了条件・検証・レビューの基準を変えない**。変えてよいのは、1 task に詰める量と、task にどこまで細かく書くかだけ。
  上位の worker は必須テスト 5〜8 件程度、軽い worker は 2〜3 件程度を目安にし、大きい ticket は前半と後半(A・B1・B2a のように)に分けて順に投函する。
  worker が「未着手」や一部だけのブロックで返してきたら、同じ task を投函し直さず、さらに小さく割って出し直す。
  モデルごとの実測の目安は [references/worker-calibration.md](references/worker-calibration.md)。
- **依存し合わない ticket は、`git worktree add` で作業ツリーを分けて並行に起動する**。PR は積み重ねにせず、マージの順は orchestrator が決める。
  並行の worker に E2E(実際のサーバーを起動するテスト)を同時に回させない。ファイルが重ならないことは安全の条件にならない。
  dev サーバーは作業ツリー全体を読むので、別の worker の書きかけのコードで、関係のないところが落ちる。E2E は 1 本ずつ回すか、worktree ごとに E2E のポートも分ける
  (worktree を分けても、Playwright の `reuseExistingServer` が固定のポートを取り合い、他の worktree のサーバーに当たる)。
  ポートやローカルの DB がぶつかる repo では task に注意を書き、ぶつかる検証は orchestrator 側でまとめて回す。
- **worker は原則として新しく起動する**。初回の task は新しい pane に投函する。同じ ticket の修正の往復では、前の worker の pane が生きていて文脈が健全なら、
  同じ pane に修正の task を投函してよい。報告が誤っている、堂々巡りしている、同じ指摘が 2 往復続く、のように文脈が汚れたら、新しい起動に戻す。
  新しく起動するのは worker だけで、orchestrator は同じセッションのまま、ゴール、レビューの結果、往復の回数を覚えておく。
- 新しく起動するときは、次のコマンドを使う。`ensure_worker_pane.sh` は agent をふだんの承認・sandbox の設定のまま起動し(役割は task ファイルの役割宣言で伝える)、
  準備完了の確認と pane の並べ方をそろえる。分割して tiled で並べるので、そのあとで `tmux break-pane` や `new-window` で別のウィンドウへ移したり隠したりしない。
  狭くなったら、終わった worker の pane を閉じて場所を空ける。

```sh
worker_agent=<codex|claude|pi>
worker_role=<implementer|reviewer|investigator|verifier>
worker=$(bash <skill-dir>/scripts/ensure_worker_pane.sh "$worker_agent" <対象リポジトリの絶対パス> "$worker_role")
```

- worker 専用の起動オプション(`codex -p worker` など)を使うなら、設定ファイル `${AGENT_ORCHESTRATE_WORKERS:-~/.config/agent-orchestrate/workers.sh}` で
  `agent_invocation`(起動コマンドの配列)を `$agent` ごとに差し替える。script がこのファイルを source する。
- Herdr の中では、上のコマンドが同梱の `scripts/herdr_start_agent.sh "$worker_role" -- "$worker_agent" ...` を実行する。
  この script は `herdr agent start` を包んだもので、`herdr` と `jq` が要る。対象 repo の Herdr workspace を使い回し、
  対話の zsh で端末の初期化を済ませてから agent を起動する。起動したら、`herdr agent start` の結果に含まれる `pane_id` を `$worker` として受け取る。
  role 名で探し直すと古い agent の登録を拾うことがあるので、探し直さない。こうして、投函する側とされる側が同じ `<worker-role>` / `wN:pN` を持つ。
- **投函の前に、worker が入力を受け付ける状態かを確かめる**。`ensure_worker_pane.sh` は agent ごとの準備完了マーカーを確かめてから worker の ID を返す
  (codex: 入力欄の `›` プロンプト、claude: ステータス行の `Ctx:`、pi: ステータス行の `(auto)`)。マーカーを確かめられなければタイムアウトしてエラーで終わるので、
  自動で回避せず、pane を見てユーザーに対応を相談する。起動直後の `idle` だけを根拠に task を送らない。tmux では念のため、**投函の直前にも until ループでもう一度確かめる**
  (1 回の capture では足りない。起動バナーが出ている間に投函すると丸ごと飲まれる)。

```sh
for i in $(seq 1 30); do
  snap=$(tmux capture-pane -p -t "$worker")
  if grep -qE "loading|Initializing|MCP startup" <<<"$snap"; then sleep 2; continue; fi
  grep -qE "›|Ctx:|Ask anything|\(auto\)" <<<"$snap" && break   # agent ごとの入力プロンプト
  sleep 2
done
```

- **その repo で初めて起動したときは、信頼の確認ダイアログを片付けてから投函する**。準備完了マーカーはダイアログの間は出ないので、tmux でも Herdr でも待ちのタイムアウトに落ちる。
  task を送る前に `tmux capture-pane -p -t "$worker" | tail -15`(Herdr では `herdr pane read`)でダイアログが出ていないかを見る。
  前回出なかったから今回も出ない、とは考えず毎回見る。
  - claude: 「フォルダを信頼するか」の 1 段。orchestrator が 1 回だけ `Enter`(既定で選ばれている「1. Yes, I trust this folder」)を送る。
  - codex: 「ディレクトリの信頼」と「hooks の信頼」の 2 段。`Enter` 1 回では 2 段目で止まったままになり、そこへ task を投函すると本文が丸ごと吸い込まれて、
    worker は何もせずに終わる。`›` プロンプトが出るまで確かめながら、**残っている段の数だけ**答える
    (同じ repo の codex をすでに起動していれば出ない。1 段目で `ensure_worker_pane.sh` の判定が通り、出会わないこともある)。

  これは初回起動の環境の確認で、task の実行中の設計の承認とは別物なので、同じ pane への 1 回きりの介入として扱ってよい。
- **route manifest を作り、courier を起動する**。task の slug ごとに `route_dir=$(mktemp -d /tmp/<slug>-route.XXXXXX)` を作り、`route_file="$route_dir/route"` とする。
  続けて `bash <skill-dir>/scripts/report_route.sh <route-file> <task-id> <report-file> "$worker_role" "$worker"` を実行する。
  - script は、起動時の環境変数(`HERDR_PANE_ID` / `TMUX_PANE`)で投函する側の pane を確かめ、`transport`、`origin`、`worker_role`、`worker_pane`、`reply_to`、
    `task_id`、`report_file` を新しい manifest に固定し、`<report-file>.done` マーカーを見張る courier を起動する。
    この環境変数は、ここで manifest を作るときに手元で確かめるためだけに使う。task・worker・報告の受け渡しには使わない。
  - manifest も courier も投函のたびに新しく作る。同じ pane に投函し直す場合も同じで、前の manifest を使い回したり上書きしたりしない。
  - tmux では courier を tmux server の `run-shell -b` で起動するので、投函したコマンドの shell が終わったあとも、worker が終わるまで待てる
    (`nohup` や `disown` だけだと、終了時に子プロセスを片付ける agent tool のもとでは courier が先に落ちることがある)。
  - 修正のラウンドでは、`<task-id>` にラウンドを入れる(例: `<slug> fix-<N>`)。`[報告]` 行は courier が manifest から組み立て、
    `task_id`、`origin=<pane-id>`、`worker=<pane-id>`(Herdr では `worker=<role>/<pane-id>`)が入るので、どのラウンドの報告かを見分けられる。

### 3. タスクファイル作成

- `/tmp/<slug>-task.md` に [references/task-template.md](references/task-template.md) の形で書く。
- 新しい worker がこのファイルだけで作業できるように書く。修正の依頼では、前回の report のパス、レビューで落とした理由、期待する直しの結果を必ず入れる。
- 必ず入れるもの: 対象の repo、前提の文脈、仕様(完了条件)、Workflow 1 で決めた検証の 2 段、repo 固有の注意、名指ししたコマンド以外を実行しない指示、
  報告の手順、commit の禁止、役割宣言(worker 自身が実装すること。分けて投函させたいときはその範囲を書く)。
- 報告の手順には、**`mark_report_done.sh` の絶対パスと report ファイルの絶対パス**を書く(`bash mark_report_done.sh <report-file> <完了|ブロック> <1行要約>`。
  全体の例は task-template)。worker は起動したときの skill の一覧しか知らないことがあり、直接呼ぶのは `mark_report_done.sh` だけ
  (tmux / herdr の送信 script は投函する側の courier が使う)。「ブロックしたときも必ず報告する」「done マーカーを作るところまでが完了条件」と書く。
  report だけ書いて `mark_report_done.sh` を忘れると、報告は届かない。
- manifest のパス、pane ID、transport は書かない。worker から tmux / herdr を直接叩く手順も書かない(sandbox が socket への接続を遮る。理由は troubleshooting)。
- worker の pane は報告のあとに閉じるので、あとで pane の scrollback には頼れない。要る事実は必ず report ファイルに書かせる。
- worker が軽いほど、判断の余地を task の側で潰す。写すファイル、API の形、テスト名を名指しする。テストの組み方が見て分からないとき
  (偽の LLM、外部 API の stub など)は、使う部品とコードの例を task に書く。例が無いと、実装だけ入れてテストを書かずに返してきやすい。
- worker の sandbox からは届かない下準備は、投函の前に orchestrator が済ませる。依存の install(registry との通信、pnpm の
  `allowBuilds` のような build スクリプトの許可)や、ブランチ・worktree の作成がこれに当たる。worker が自分で回避しようとして止まるのを防ぐため。

### 4. 投函

- [references/delivery.md](references/delivery.md) の手順で、worker の pane へ 1 行のメッセージを送る。

```
/tmp/<slug>-task.md を読んで、その指示どおり作業してください。完了・ブロック時の報告手順もそのファイルにあります。
```

- **task の投函は、worker が処理を始めたのを確かめるまでを完了とする**。送るだけで止めると、入力欄に残ったままの task や、起動直後の再描画で飲まれた本文を見逃す。
  - Herdr: 送る前に `idle` だったなら、`herdr_send.sh` の成功出力だけで完了とせず、`herdr pane get "$worker"` で `agent_status=working` に変わったことを確かめる。
    変わらなければ `herdr_send.sh` が Enter だけを 1 回送り直す。
  - tmux: `tmux_send.sh` が正常に終わっても、tmux server が受け付けたことしか分からない。送ったあと、`tmux capture-pane` で `Working` や `esc to interrupt` のような
    実行中の表示に変わるのを最大 20 秒待つ。変わらなければ ENTER を 1 回だけ送り直す。それでも変わらず、入力欄が**空**(プレースホルダーが出ている)なら、
    本文が丸ごと落ちたので、本文を 1 回だけ送り直してよい(空の入力欄へ送り直しても二重の投函にならない。入力欄に本文が残っているなら ENTER だけを送り直す)。
  - それでも確かめられなければ投函の失敗として止まり、「worker に任せた」とは報告しない。
- **courier は必ず使う**。orchestrator も worker もどの CLI エージェントでもよく、入れ子の委譲も起こりうる。courier による `[報告]` の着弾は、
  ホストの CLI の機能に頼らずに成り立つただ 1 つの経路で、やりとり全体が端から端まで通ったかもこれで確かめる。
- **追加で使ってよい経路**: ホストの CLI の Bash 相当のツールが、「バックグラウンドで実行した処理が終わると通知が届き、ターンが自動で再開する」ことを
  **ツール自身の説明文に明記している**場合に限り、投函と同じターンで
  `bash <skill-dir>/scripts/wait_for_report.sh --i-confirmed-run-in-background-auto-resumes-my-turn /tmp/<slug>-report.md`
  をその機能で起動しておける(例: Claude Code の Bash tool の `run_in_background: true`)。これで `report_file.done` が現れたことを、キー入力なしで知れる。
  - 通知には `worker完了検知: status=... summary=... delivery=... report=<path>` が入る。並行の投函や修正のラウンドが重なっていても、どの task の完了かは `report=` のパスで見分ける(推測で決めない)。
  - この機能があると確かめられないなら使わない。シェルの `&` では代わりにならず、通知は来ない(script が確認のフラグを必須にしているのはこのため)。
  - 使っても courier は省かない。並行の投函を混ぜないこと、この機能を持たないホストへの経路、配送の記録(receipt)は courier の役目のまま。

### 5. 待機(=ターン終了)

- 投函したら「worker に任せた。報告が届いたらレビューする」とユーザーに伝え、ターンを終える。
- 報告が届いたことには、次のどちらかで気づく。どちらが先でも、Workflow 6 のレビューの手順は同じ。
  - courier が打ち込む `[報告] ...` 行が、起動元の pane に届く(どの CLI エージェントでも使える必須の経路)。
  - `wait_for_report.sh` を起動していれば、バックグラウンドのタスクの完了通知が届く。この通知が先に来たら、`[報告]` 行を待たずに report ファイルを直接読んでレビューへ進んでよい。
- **報告も通知も来ないまま様子を見るとき**(ユーザーに「様子を見て」と言われたときなど)は、自分で作った route manifest にある
  `report_file`・`<report_file>.delivered`・`<report_file>.undeliverable` を直接読む。
  - report が出来ていれば、worker の pane には触らずに Workflow 6 のレビューへ進む。`confirmed=unconfirmed` でも、report と done マーカーはもう出来ている
    (送るコマンドは成功していて、着弾による表示の変化を確かめられなかっただけ)。
  - report が出来ていないときだけ、`tmux capture-pane -p -t <worker>` で 1 回だけ様子を見る(1 回きりの確認で、ポーリングではない)。
  - ここを怠ると、report と worker の作業ツリーにある未 commit の diff が、レビューも commit もされないまま放置されかねない。
  - 原因の切り分けは [references/troubleshooting.md](references/troubleshooting.md)。

### 6. レビュー

- レビューの最初に `bash <skill-dir>/scripts/check_delivery.sh <repo> <task-file> <base-commit>` を実行する。`check_delivery: status=fail` なら diff を読まずに差し戻し、
  出力をそのまま修正の task に貼る。pass のときだけ、以下のレビューに進む。
- **報告がどのやりとりのものかを照らし合わせ、worker の pane を閉じる**。
  - `[報告]` 行で気づいた場合: その行、route manifest、report ファイルを読む。manifest の `task_id`・`worker_pane`・`report_file` と合わない報告は、別のやりとりのものとして扱い、worker を閉じない。
    Herdr 宛ての報告は `herdr_send.sh` が Herdr の pane へ直接入力するので、外側の tmux の pane の scrollback ではなく、この会話に届いたものを正とする。
    `worker=<role>/<pane-id>` が今回投函した worker と一致し、report ファイルを読めたら閉じる。自分の pane と一致する場合、報告に pane id が無い場合、まだ report を読めていない場合は閉じない。
  - `wait_for_report.sh` の通知で気づいた場合: `$worker`(Workflow 2 で確保した pane ID)をそのまま使って閉じてよい。通知の `delivery=` が `delivered` 以外
    (`undeliverable`・`unconfirmed`・`pending`)なら `[報告]` は届いていないので、ユーザーへの報告に「この worker の `[報告]` は配送できなかった」と書く。
  - Workflow 5 のディスク上の確認で気づいた場合: `$worker` をそのまま使って閉じてよい。閉じても作業ツリーの diff は残るので、続くレビューの手順を必ずやり切る。

```sh
reported_worker='<[報告] 行の worker=<worker-role>/wN:pN または worker=%NN から pane ID を転記>'
worker="${worker:-$reported_worker}"
if [[ "${HERDR_ENV:-}" == "1" && -n "${HERDR_PANE_ID:-}" ]]; then
  [[ "$worker" != "$HERDR_PANE_ID" ]] && herdr pane close "$worker"
elif [[ -n "${worker:-}" && "$worker" != "${TMUX_PANE:-}" ]]; then
  tmux kill-pane -t "$worker" || true
fi
```

- **報告を読んだら、まず証拠を退避する**。`/tmp` はセッションの区切りやモデルの切り替えで丸ごと消えることがあり、report と検証のログが消えると裏取りの根拠がなくなる。
  次のラウンドの worker が「読むべき計画ファイルが無い」でブロックしたり、裏取りができずに全量を回し直したりすることにもなる。
  worker の書き込み先は sandbox の制約があるので `/tmp` のままにし、届いた直後に orchestrator が退避する。

```sh
slug=<slug>
keep=~/.local/state/agent-orchestrate/"$slug"
mkdir -p "$keep" && cp -f /tmp/"$slug"*-report.md /tmp/"$slug"*.log /tmp/"$slug"-task.md "$keep"/ 2>/dev/null
```

  長い調査の計画のように、複数のラウンドで参照する成果物も同じ場所に退避し、以後は退避先を参照する。
- **worker が起動したまま残したプロセスを止める**。worker が dev server や workerd を止め忘れ、ポート(例: 5173)を握ったまま pane を閉じることがある。
  実機で確かめる前に `lsof -nP -iTCP:<port> -sTCP:LISTEN` で持ち主を確かめ、今回の worker が起動したものなら止める。task にも「撮影のあとで dev server を止める」と書く。
- `git status` / `git diff` で変更を精読する。仕様と合っているか、参照が残っていないか、トークンや命名が妥当かまで見る。
- まず、report に受け入れ基準ごとのテストの対応表(ファイル:テスト名)があるかを確かめる。表が無ければ検証せずに差し戻す。
  UI の task では、指定した場面のスクリーンショットと画像のパスがあるかを確かめ、orchestrator が画像を見る。
- 検証の記録を確かめる。変更が触った層に応じて、repo の検証コマンド(repo の AGENTS.md などに書かれた typecheck・test・lint など)の成功の記録を見る。
  重い repo では、重い段を orchestrator がここで実行する。記録を採用する条件は次の 4 つ。
  1. 記録にコマンドと真の exit code がある
  2. 対応するログファイルが実在し、末尾がその task の正常な完了のまとめ(テストの集計、build の完了行など)と食い違わない
  3. 記録の時刻が、この往復の作業時間と合う
  4. 記録のあとで検証の入力が変わっていない(レビュー中の diff の精読は入力を変えない)
- **回し直すのは次の場合だけ**: 成功の記録が無い、記録とログが食い違う、ログが途中で切れている、レビューでコードに手を入れた、
  実行順や環境によるフレークを疑う具体的な根拠がある。回し直すときはまず該当する 1 task に絞り、全量を回し直すのは実際に食い違いが見つかったときだけにする。
  worker が task ファイルの名指しで一部の suite だけを回していた場合も、その report を成功の根拠にせず、ここで検証コマンドの記録を確かめる。
  worker が「既存の失敗」「環境の問題」と書いてきたら、修正前の commit で同じ失敗が出たログが無い限り差し戻す。
- **合否は真の exit code で決める**。`cmd | grep 'fail' | ...` のようなパイプで要約すると、exit code がパイプで差し替わる。
  そのうえ、テストランナーの外で起きた失敗(script の中の `cd` の失敗、ランナー自体の異常終了)はパターンに現れず、「全部緑」に見える。
  `cmd > log 2>&1; echo exit=$?` で先に exit code を確定し、ログの grep は内訳をつかむためにだけ使う。

### 7. 判定

- **合格**: 仕上げる(commit、push、ユーザーへの最終報告)。commit は repo の規約に従う。
- **不合格**: 指摘を箇条書きにした修正の task ファイル `/tmp/<slug>-fix-<N>.md` を作り、2 へ戻る。
  前の worker を続けて使えないときは、新しい worker のセッションを起動して投函する。
  修正のラウンドの report は `/tmp/<slug>-fix-<N>-report.md` にし、`report_route.sh` の `<task-id>` にもラウンドを入れて、`[報告] <slug> fix-<N> ...` の形で届くようにする
  (前回の report を上書きしないため、また、どの往復への返事かを見分けるため)。
- **往復の回数を 1 増やし、止まる条件を確かめる**。上限の 10 回は終わらないやりとりを止める安全弁で、指摘に沿って前に進んでいる往復を早く打ち切るためのものではない。
  毎回、前回の指摘が片付き、残る指摘が新しく狭いものになっている限り、回数が重なっても修正を頼み続ける
  (例: 1 往復目は範囲外の書き換え、2 往復目はコメントの戻し忘れ、と指摘が変わりながら減っていく)。
  次のどちらかに当たったら、回数に関係なく止まり、状況と残りの課題をユーザーに報告して指示を仰ぐ。
  - 10 回修正を頼んでもゴールに届かない
  - 同じ指摘が 2 往復続けて片付かない、または直した所が次の往復で元に戻る(前に進んでいない)

  ユーザーが上限を変える・なくすと明示したときはそれに従う。

### 8. 積み重ねた PR のマージ

後ろの PR が base にしているブランチを `--delete-branch` で先に消すと、GitHub は後ろの PR の base を付け替えずに閉じてしまう。
積み重ねた PR は、次の PR の base を先に main へ変えてからマージし、ブランチの削除は最後にまとめて行う。
マージの権限をもらっているときは、orchestrator が自分で判断してマージし、ユーザーにマージを頼まない。

### 9. 最終報告

- ユーザーへ: 達成したゴール、変更の概要、検証の結果、往復の回数、残りの課題(あれば)。
