---
name: agent-orchestrate
description: "tmux または Herdr の pane で動く worker(codex / claude / pi)へ実装・調査・検証を任せ、完了報告のレビューと再依頼を繰り返してゴールまで進めるときに使う。「オーケストレーションモードで」と明示されたら、以降のセッションでは通常のタスクを毎回 worker へ任せるモードに入る。in-process の subagent(Agent tool など)とは別物。pane へ 1 行を送るだけ・時刻を指定して送るのは pane-send。"
---

# agent-orchestrate

## 用途ごとの入口

- worker に実装を任せ、レビューと再依頼を繰り返す: このファイルを通して読み、各段で指した references をその段に入るときに読む。
- pane へ 1 行を送るだけ・決まった時刻に送る: この skill ではなく pane-send skill を使う。
- 報告が届かない、worker が止まった・起動しない: [references/troubleshooting.md](references/troubleshooting.md) を読む。

`<skill-dir>` は、この skill(SKILL.md のあるディレクトリ)の絶対パスを指す。送信スクリプトは、隣に入れた pane-send skill の `scripts/` にある
(courier はそこを呼ぶ。無ければ courier がエラーで止まる)。

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
- 役割の組み合わせの例は [references/worker-calibration.md](references/worker-calibration.md)。
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

- **前提チェック**: orchestrator は tmux か Herdr の pane の中で動いている必要がある。どちらでもなければ worker を起動せずに止まり、
  tmux / Herdr の中でセッションを開き直すようユーザーに頼む。ポーリングや自分での実装に切り替えて代わりにしない。
  確かめ方(Herdr では `$HERDR_PANE_ID` が返信先の正本)と、会話を再開したあとに自分の pane id を確かめ直す手順は
  [references/worker-launch.md](references/worker-launch.md)。
- **worker の role は task ごとに選ぶ**。`implementer`(実装・修正)、`reviewer`(独立したレビュー)、
  `investigator`(原因の調査・再現)、`verifier`(テスト・受け入れの確認)のうち、今回任せる主な目的にいちばん近いものを 1 つ選ぶ。
  role はただの表示名ではなく、ID の照合・報告・片付けのキーなので、曖昧な `worker` や、いつも同じ `implementer` を使わない。
- **worker の agent は `codex` / `claude` / `pi` から選ぶ**。ユーザーが明示していればそれに従う。
  **明示がなければ既定は `codex`**。選択 UI で確かめる場合も、いちばん上の選択肢を `codex` にする(質問ツールを使うなら、先頭 = 既定 = `codex`)。
  一度選んだ agent は、同じセッションの以後の投函でも既定にし、往復のたびに聞き直さない(ユーザーが変更を明示したときだけ切り替える)。
  pi は、明示されていなくても軽い実装の任せ先に選んでよい。
- **task の性質で worker の格と 1 task の量を選ぶ**。agent の種類やモデル名で、rule・完了条件・検証・レビューの基準は変えない。
  目安と実測は [references/worker-calibration.md](references/worker-calibration.md)。
- **依存し合わない ticket は、`git worktree add` で作業ツリーを分けて並行に起動する**。並行の worker に E2E を同時に回させない
  (理由とポートの分け方は [references/worker-launch.md](references/worker-launch.md))。
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

- worker 専用の起動オプションと Herdr での起動の中身は [references/worker-launch.md](references/worker-launch.md)。
- **投函の前に、worker が入力を受け付ける状態かを確かめ、その repo で初めて起動したときは信頼の確認ダイアログを片付ける**。
  起動直後の `idle` だけを根拠に task を送らない。確かめ方は [references/dispatch.md](references/dispatch.md)(毎回読む)。
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

- pane-send skill の手順で、worker の pane へ 1 行のメッセージを送る。

```
/tmp/<slug>-task.md を読んで、その指示どおり作業してください。完了・ブロック時の報告手順もそのファイルにあります。
```

- **task の投函は、worker が処理を始めたのを確かめるまでを完了とする**。確かめ方と送り直しの条件は [references/dispatch.md](references/dispatch.md)。
  確かめられなければ投函の失敗として止まり、「worker に任せた」とは報告しない。
- **courier は必ず使う**。orchestrator も worker もどの CLI エージェントでもよく、入れ子の委譲も起こりうる。courier による `[報告]` の着弾は、
  ホストの CLI の機能に頼らずに成り立つただ 1 つの経路で、やりとり全体が端から端まで通ったかもこれで確かめる。
- **追加で使ってよい経路**: ホストの CLI が「バックグラウンドの処理が終わると通知が届き、ターンが自動で再開する」と
  ツール自身の説明文に明記している場合に限り、`wait_for_report.sh` を併用できる。条件と通知の読み方は [references/dispatch.md](references/dispatch.md)。

### 5. 待機(=ターン終了)

- 投函したら「worker に任せた。報告が届いたらレビューする」とユーザーに伝え、ターンを終える。
- 報告が届いたことには、次のどちらかで気づく。どちらが先でも、Workflow 6 のレビューの手順は同じ。
  - courier が打ち込む `[報告] ...` 行が、起動元の pane に届く(どの CLI エージェントでも使える必須の経路)。
  - `wait_for_report.sh` を起動していれば、バックグラウンドのタスクの完了通知が届く。この通知が先に来たら、`[報告]` 行を待たずに report ファイルを直接読んでレビューへ進んでよい。
- 報告も通知も来ないまま様子を見るとき(ユーザーに「様子を見て」と言われたときなど)は、worker の pane に聞き直さず、
  [references/troubleshooting.md](references/troubleshooting.md) の「報告も通知も来ないまま様子を見るとき」の手順で、ディスク上の report を読む。

### 6. レビュー

- レビューの最初に `bash <skill-dir>/scripts/check_delivery.sh <repo> <task-file> <base-commit>` を実行する。`check_delivery: status=fail` なら diff を読まずに差し戻し、
  出力をそのまま修正の task に貼る。pass のときだけ、以下のレビューに進む。
- **報告がどのやりとりのものかを照らし合わせてから、worker の pane を閉じる**。manifest と合わない報告は別のやりとりのものとして扱い、閉じない。
- **報告を読んだら、まず証拠(report・ログ・task)を退避する**。`/tmp` は消えることがある。
- **worker が起動したまま残したプロセス(dev server など)を止める**。
- 照合・閉じ方・退避・プロセスの止め方のコマンドは [references/review.md](references/review.md)(レビューのたびに読む)。
- `git status` / `git diff` で変更を精読する。仕様と合っているか、参照が残っていないか、トークンや命名が妥当かまで見る。
- まず、report に受け入れ基準ごとのテストの対応表(ファイル:テスト名)があるかを確かめる。表が無ければ検証せずに差し戻す。
  UI の task では、指定した場面のスクリーンショットと画像のパスがあるかを確かめ、orchestrator が画像を見る。
- 検証の記録を確かめる。変更が触った層に応じて、repo の検証コマンド(repo の AGENTS.md などに書かれた typecheck・test・lint など)の成功の記録を見る。
  記録を採用する 4 つの条件と、回し直す場合は [references/review.md](references/review.md)。
- **合否は真の exit code で決める**。パイプで要約しない(`cmd > log 2>&1; echo exit=$?`)。

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

後ろの PR の base を先に main へ変えてからマージし、ブランチの削除は最後にまとめる。理由は [references/stacked-pr.md](references/stacked-pr.md)。
マージの権限をもらっているときは、orchestrator が自分で判断してマージする。

### 9. 最終報告

- ユーザーへ: 達成したゴール、変更の概要、検証の結果、往復の回数、残りの課題(あれば)。
