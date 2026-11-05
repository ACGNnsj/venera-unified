#!/usr/bin/env bash
RID=41264313204
for i in $(seq 1 60); do
  S=$(gh api repos/ACGNnsj/venera-unified/actions/runs/$RID --jq '.status+" "+(.conclusion//"-")')
  echo "$(date +%H:%M) $S" >> .scratch/tmp/j6-watch.log
  case "$S" in completed*) break;; esac
  sleep 45
done
gh api "repos/ACGNnsj/venera-unified/actions/runs/$RID/jobs?per_page=100" --jq '.jobs[]|[.name,(.conclusion//"-"),.started_at,.completed_at]|@tsv' >> .scratch/tmp/j6-watch.log
echo DONE >> .scratch/tmp/j6-watch.log
