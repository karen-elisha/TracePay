# TracePay IEEE Conference Paper

## Files

| File | Purpose |
|------|---------|
| `tracepay_ieee.tex` | Main LaTeX source (IEEEtran conference style) |
| `tracepay_refs.bib` | BibTeX bibliography (18 references) |

## How to Compile

```bash
cd paper/
pdflatex tracepay_ieee.tex
bibtex   tracepay_ieee
pdflatex tracepay_ieee.tex
pdflatex tracepay_ieee.tex   # 3rd pass resolves all cross-references
```

You need a LaTeX distribution with `IEEEtran.cls` installed
(TeXLive, MiKTeX, or Overleaf — all include it by default).

### Overleaf (recommended for quick preview)
1. Create a new Overleaf project → *Upload* → drag both files.
2. Set compiler to **pdfLaTeX**.
3. Click **Recompile**.

## Paper Structure

| Section | Content |
|---------|---------|
| Abstract | Problem, 5 mechanisms, test results, gas figures |
| I. Introduction | Trade-finance pain points, TracePay contributions |
| II. Background | Blockchain trade finance, escrow, oracles, factoring literature |
| III. System Design | Actors/roles, state machine FSM, oracle pricing formula, DoA, payment waterfall, factoring equations |
| IV. Implementation | Tech stack, Order struct listing, oracle guard listing, pull-payment listing |
| V. Evaluation | 16-test table (all passing), full gas table, deployment footprint |
| VI. Security Analysis | Reentrancy, RBAC, oracle manipulation, front-running, integer safety, duplicate invoices |
| VII. Discussion | Limitations (oracle trust, ETH volatility, single-chain), future work |
| VIII. Conclusion | Summary |
| References | 18 BibTeX entries |

