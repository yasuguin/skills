# Changesets

PR ごとに、ここへ変更 1 件分の記録（`pnpm changeset` で作る Markdown）を足す。main に入ると、Actions の version PR がこれを集めて `CHANGELOG.md` と版を上げ、merge すると `v<版>` の tag と GitHub Release を作る。
