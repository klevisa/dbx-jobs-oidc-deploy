# dbx-jobs-oidc-deploy

Deploys two Databricks jobs from GitHub Actions with **no stored secrets**, using least privilege.

```
GitHub Actions (env: prod, branch: main)
   │  OIDC token  sub = repo:klevisa/dbx-jobs-oidc-deploy:environment:prod
   ▼
Databricks federation policy ──► deployer SP  (workspace user, not admin)
                                    │ roles/servicePrincipal.user (only these two)
                        ┌───────────┴───────────┐
                   job-sp-etl             job-sp-reports      ← jobs' run_as identities
```

* The deployer can create/update jobs and set `run_as` to the two job SPs — it can't act as any other SP, and the job SPs hold no secrets or deploy rights.
* Only `main` can use the `prod` environment, and the federation policy subject only matches that environment, so a feature branch gets no token Databricks accepts.
* Job SPs are pre-created by `setup/setup.sh`, not by CI.

Setup: edit `setup/config.env`, run `./setup/setup.sh`, then `./setup/verify.sh`.
