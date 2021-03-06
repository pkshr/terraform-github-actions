#!/bin/bash

source /usr/local/actions.sh

debug

setup
init-backend
select-workspace
set-plan-args

PLAN_DIR=$HOME/$GITHUB_RUN_ID-$(random_string)
rm -rf "$PLAN_DIR"
mkdir -p "$PLAN_DIR"
PLAN_OUT="$PLAN_DIR/plan.out"

if [[ "$INPUT_AUTO_APPROVE" == "true" && -n "$INPUT_TARGET" ]]; then
    for target in $(echo "$INPUT_TARGET" | tr ',' '\n'); do
        PLAN_ARGS="$PLAN_ARGS -target $target"
    done
fi

if [[ -n "$GITHUB_TOKEN" ]]; then
  update_status "Applying plan in $(job_markdown_ref)"
fi

exec 3>&1

function plan() {

    local PLAN_OUT_ARG
    if [[ -n "$PLAN_OUT" ]]; then
      PLAN_OUT_ARG=-out="$PLAN_OUT"
    fi

    set +e
    (cd $INPUT_PATH && terraform plan -input=false -no-color -detailed-exitcode -lock-timeout=300s $PLAN_OUT_ARG $PLAN_ARGS) \
        2>"$PLAN_DIR/error.txt" \
        | $TFMASK \
        | tee /dev/fd/3 \
        | sed '1,/---/d' \
            >"$PLAN_DIR/plan.txt"

    PLAN_EXIT=${PIPESTATUS[0]}
    set -e
}

function apply() {

    set +e
    (cd $INPUT_PATH && terraform apply -input=false -no-color -auto-approve -lock-timeout=300s $PLAN_OUT) | $TFMASK
    local APPLY_EXIT=${PIPESTATUS[0]}
    set -e

    if [[ $APPLY_EXIT -eq 0 ]]; then
        update_status "Plan applied in $(job_markdown_ref)"
    else
        update_status "Error applying plan in $(job_markdown_ref)"
        exit 1
    fi
}

### Generate a plan

plan

if [[ $PLAN_EXIT -eq 1 ]]; then
    if grep -q "Saving a generated plan is currently not supported" "$PLAN_DIR/error.txt"; then
        PLAN_OUT=""

        if [[ "$INPUT_AUTO_APPROVE" == "true" ]]; then
          # The apply will have to generate the plan, so skip doing it now
          PLAN_EXIT=2
        else
          plan
        fi
    fi
fi

if [[ $PLAN_EXIT -eq 1 ]]; then
    update_status "Error applying plan in $(job_markdown_ref)"
    exit 1
fi

### Apply the plan

if [[ "$INPUT_AUTO_APPROVE" == "true" || $PLAN_EXIT -eq 0 ]]; then
    echo "Automatically approving plan"
    apply

else

    if [[ -z "$GITHUB_TOKEN" ]]; then
      echo "GITHUB_TOKEN environment variable must be set to get plan approval from a PR"
      echo "Either set the GITHUB_TOKEN environment variable or automatically approve by setting the auto_approve input to 'true'"
      echo "See https://github.com/dflook/terraform-github-actions/ for details."
      exit 1
    fi

    if ! github_pr_comment get >"$PLAN_DIR/approved-plan.txt"; then
        echo "Approved plan not found"
        exit 1
    fi

    if plan_cmp "$PLAN_DIR/plan.txt" "$PLAN_DIR/approved-plan.txt"; then
        apply
    else
        debug_log diff "$PLAN_DIR/plan.txt" "$PLAN_DIR/approved-plan.txt"
        update_status "Plan not applied in $(job_markdown_ref) (Plan has changed)"
        exit 1
    fi
fi

output
