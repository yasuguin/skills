# 積み重ねた PR のマージ

SKILL.md の Workflow 8 の詳細。

後ろの PR が base にしているブランチを `--delete-branch` で先に消すと、GitHub は後ろの PR の base を付け替えずに閉じてしまう。
積み重ねた PR は、次の PR の base を先に main へ変えてからマージし、ブランチの削除は最後にまとめて行う。
マージの権限をもらっているときは、orchestrator が自分で判断してマージし、ユーザーにマージを頼まない。
