use std::{collections::BTreeMap, fmt::Display, io::Write, path::PathBuf};

use clap::{Args, Subcommand};
use eyre::OptionExt;
use forgejo_api::{
    Forgejo, ForgejoError,
    structs::{
        ActionRun, ActionRunJob, ActionVariable, CreateOrUpdateSecretOption, CreateVariableOption,
        ListActionRunsQuery, RepoGetActionJobLogsQuery, UpdateVariableOption,
    },
};
use hyper::StatusCode;
use time::Duration;
use tokio::io::AsyncWriteExt;

use crate::{
    SpecialRender, ftl_bail, ftl_eprintln, ftl_println, h,
    localization::AsFluent,
    repo::{RepoArg, RepoInfo, RepoName},
};

#[derive(Args, Clone, Debug)]
pub struct ActionsCommand {
    #[clap(help = h!("arg-remote"))]
    #[clap(long, short = 'R', global = true)]
    remote: Option<String>,

    #[clap(help = h!("arg-repo"))]
    #[clap(long, short, global = true)]
    repo: Option<RepoArg>,

    #[clap(subcommand)]
    command: ActionsSubcommand,
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsSubcommand {
    #[clap(about = h!("cmd-actions-tasks"))]
    Tasks {
        #[clap(help = h!("arg-actions-tasks-page"))]
        #[clap(long, short, default_value = "1")]
        page: u32,
    },

    #[clap(about = h!("cmd-actions-variables"))]
    Variables {
        #[clap(subcommand)]
        command: ActionsVariablesSubcommmand,
    },

    #[clap(about = h!("cmd-actions-secrets"))]
    Secrets {
        #[clap(subcommand)]
        command: ActionsSecretsSubcommmand,
    },

    #[clap(about = h!("cmd-actions-dispatch"))]
    Dispatch {
        #[clap(help = h!("arg-actions-dispatch-name"))]
        name: String,

        #[clap(help = h!("arg-actions-dispatch-ref"))]
        r#ref: String,

        #[clap(help = h!("arg-actions-dispatch-inputs"))]
        #[clap(long, short = 'I', value_parser = parse_dispatch_kvs)]
        inputs: Vec<(String, String)>,
    },

    #[clap(about = h!("cmd-actions-view"))]
    View {
        #[clap(help = h!("arg-actions-view-run"))]
        run: String,

        #[clap(help = h!("arg-actions-view-job"))]
        #[clap(long, short)]
        job: Option<i64>,

        #[clap(help = h!("arg-actions-view-logs"))]
        #[clap(long)]
        logs: bool,

        #[clap(help = h!("arg-actions-view-step"))]
        #[clap(long)]
        step: Option<u32>,

        #[clap(help = h!("arg-actions-view-attempt"))]
        #[clap(long)]
        attempt: Option<i64>,
    },

    #[clap(about = h!("cmd-actions-jobs"))]
    Jobs {
        #[clap(help = h!("arg-actions-jobs-run"))]
        run: String,
    },

    #[clap(about = h!("cmd-actions-logs"))]
    Logs {
        #[clap(help = h!("arg-actions-logs-job"))]
        #[clap(long, short)]
        job: Option<i64>,

        #[clap(help = h!("arg-actions-logs-run"))]
        #[clap(long)]
        run: Option<String>,

        #[clap(help = h!("arg-actions-logs-out"))]
        #[clap(long, short)]
        out: Option<PathBuf>,

        #[clap(help = h!("arg-actions-logs-step"))]
        #[clap(long)]
        step: Option<u32>,

        #[clap(help = h!("arg-actions-logs-attempt"))]
        #[clap(long)]
        attempt: Option<i64>,
    },
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsVariablesSubcommmand {
    #[clap(about = h!("cmd-actions-variables-list"))]
    List {
        #[clap(help = h!("arg-actions-variables-list-verbose"))]
        #[clap(long, short)]
        verbose: bool,
    },

    #[clap(about = h!("cmd-actions-variables-create"))]
    Create {
        #[clap(help = h!("arg-actions-variables-create-name"))]
        name: String,

        #[clap(help = h!("arg-actions-variables-create-data"))]
        data: Option<String>,

        #[clap(help = h!("arg-actions-variables-create-force"))]
        #[clap(long, short)]
        force: bool,
    },

    #[clap(about = h!("cmd-actions-variables-delete"))]
    Delete {
        #[clap(help = h!("arg-actions-variables-delete-name"))]
        name: String,
    },
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsSecretsSubcommmand {
    #[clap(about = h!("cmd-actions-secrets-list"))]
    List,

    #[clap(about = h!("cmd-actions-secrets-create"))]
    Create {
        #[clap(help = h!("arg-actions-secrets-create-name"))]
        name: String,

        #[clap(help = h!("arg-actions-secrets-create-data"))]
        data: String,
    },

    #[clap(about = h!("cmd-actions-secrets-delete"))]
    Delete {
        #[clap(help = h!("arg-actions-secrets-delete-name"))]
        name: String,
    },
}

impl ActionsCommand {
    pub async fn run(self, keys: &mut crate::KeyInfo, host_name: Option<&str>) -> eyre::Result<()> {
        let repo =
            RepoInfo::get_current(host_name, self.repo.as_ref(), self.remote.as_deref(), keys)?;

        let api = keys.get_api(repo.host_url()).await?;
        let repo = repo
            .name()
            .ok_or_eyre("can't figure what repo to access, try specifying with `--repo`")?;
        match self.command {
            ActionsSubcommand::Tasks { page } => view_tasks(repo, &api, page).await?,

            ActionsSubcommand::Variables { command } => match command {
                ActionsVariablesSubcommmand::List { verbose } => {
                    list_variables(repo, &api, verbose).await?
                }
                ActionsVariablesSubcommmand::Create { name, data, force } => {
                    create_variable(repo, &api, name, data, force).await?
                }
                ActionsVariablesSubcommmand::Delete { name } => {
                    delete_variable(repo, &api, name).await?
                }
            },

            ActionsSubcommand::Secrets { command } => match command {
                ActionsSecretsSubcommmand::List => list_secrets(repo, &api).await?,
                ActionsSecretsSubcommmand::Create { name, data } => {
                    create_secret(repo, &api, name, data).await?
                }
                ActionsSecretsSubcommmand::Delete { name } => {
                    delete_secret(repo, &api, name).await?
                }
            },

            ActionsSubcommand::Dispatch {
                name,
                r#ref,
                inputs,
            } => dispatch(repo, &api, name, r#ref, inputs.into_iter().collect()).await?,

            ActionsSubcommand::View {
                run,
                job,
                logs,
                step,
                attempt,
            } => view_run(repo, &api, &run, job, logs, step, attempt).await?,

            ActionsSubcommand::Jobs { run } => view_jobs(repo, &api, &run).await?,

            ActionsSubcommand::Logs {
                job,
                run,
                out,
                step,
                attempt,
            } => view_logs(repo, &api, job, run.as_deref(), out, step, attempt).await?,
        }

        Ok(())
    }
}

async fn view_tasks(repo: &RepoName, api: &Forgejo, page: u32) -> eyre::Result<()> {
    // We don't iterate this to collect all tasks (not just the ones on the first page) like the
    // issue search subcommand will do, because it's unlikely someone wants to see *all* tasks.
    let res = api
        .list_action_tasks(
            repo.owner(),
            repo.name(),
            forgejo_api::structs::ListActionTasksQuery::default(),
        )
        .page(page)
        .page_size(20)
        .await?;

    if res.total_count == Some(1) {
        println!("1 task");
    } else {
        println!("{} tasks", res.total_count.unwrap_or(0));
    }

    let SpecialRender {
        reset,
        bold,
        bright_green,
        yellow,
        bright_blue,
        ..
    } = *crate::special_render();

    for task in res.workflow_runs.unwrap_or_default() {
        let task_sym = status_symbol(task.status.as_deref());

        let sha = task.head_sha.unwrap_or_default();
        let sha = if sha.len() > 10 { &sha[0..10] } else { &sha };

        let time = if let (Some(end), Some(start)) = (task.updated_at, task.run_started_at) {
            end - start
        } else {
            Duration::default()
        };

        println!(
            "#{bold}{}{reset} [{bright_blue}{}{reset}] ({bright_blue}{}{reset}) {} {} {bright_green}{}{reset} ({}): {yellow}{}{reset}",
            task.run_number.unwrap_or(0),
            task.id.unwrap_or(0),
            sha,
            task_sym,
            task.name.unwrap_or_default(),
            time,
            task.event.unwrap_or_default(),
            task.display_title.unwrap_or_default(),
        );
    }

    Ok(())
}

async fn list_variables(repo: &RepoName, api: &Forgejo, verbose: bool) -> eyre::Result<()> {
    let variables = api
        .get_repo_variables_list(repo.owner(), repo.name())
        .all()
        .await?;

    for var in variables {
        println!("{}", DisplayActionVariable::new(var, verbose)?);
    }

    Ok(())
}

async fn create_variable(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    data: Option<String>,
    force: bool,
) -> eyre::Result<()> {
    let mut data = if let Some(data) = data {
        data
    } else {
        let mut data = String::new();
        crate::editor(&mut data, Some("variable_content.txt")).await?;
        data
    };

    match api
        .create_repo_variable(
            repo.owner(),
            repo.name(),
            &name,
            CreateVariableOption {
                // If we don't have force enabled, we will not need the data again to (potentially)
                // make another request. To avoid a clone in this case, we take the string here,
                // replacing it with an empty one.
                value: if force {
                    data.clone()
                } else {
                    std::mem::take(&mut data)
                },
            },
        )
        .await
    {
        Err(ForgejoError::ApiError(forgejo_api::ApiError {
            kind: forgejo_api::ApiErrorKind::Other(StatusCode::CONFLICT),
            ..
        })) => {
            if !force {
                ftl_bail!("msg-actions-variable-create-already_exists");
            }

            ftl_eprintln!("msg-actions-variable-create-already_exists_forced");
            api.update_repo_variable(
                repo.owner(),
                repo.name(),
                &name,
                UpdateVariableOption {
                    name: None,
                    value: data,
                },
            )
            .await?;
        }
        Err(e) => return Err(e.into()),
        Ok(()) => {}
    }

    Ok(())
}

async fn delete_variable(repo: &RepoName, api: &Forgejo, name: String) -> eyre::Result<()> {
    api.delete_repo_variable(repo.owner(), repo.name(), &name)
        .await?;
    ftl_println!("msg-actions-variable-delete-success", name);

    Ok(())
}

async fn list_secrets(repo: &RepoName, api: &Forgejo) -> eyre::Result<()> {
    let secrets = api
        .repo_list_actions_secrets(repo.owner(), repo.name())
        .all()
        .await?;

    for secret in secrets {
        println!(
            "({}) {}",
            crate::DisplayOptional(secret.created_at, "?"),
            crate::DisplayOptional(secret.name, "?")
        );
    }

    Ok(())
}

async fn create_secret(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    data: String,
) -> eyre::Result<()> {
    api.update_repo_secret(
        repo.owner(),
        repo.name(),
        &name,
        CreateOrUpdateSecretOption { data },
    )
    .await?;

    Ok(())
}

async fn delete_secret(repo: &RepoName, api: &Forgejo, name: String) -> eyre::Result<()> {
    api.delete_repo_secret(repo.owner(), repo.name(), &name)
        .await?;

    Ok(())
}

async fn dispatch(
    repo: &RepoName,
    api: &Forgejo,
    name: String,
    r#ref: String,
    inputs: BTreeMap<String, String>,
) -> eyre::Result<()> {
    let n_inputs = inputs.len();
    api.dispatch_workflow(
        repo.owner(),
        repo.name(),
        &name,
        forgejo_api::structs::DispatchWorkflowOption {
            inputs: Some(inputs),
            return_run_info: Some(false),
            r#ref: r#ref.clone(),
        },
    )
    .await?;

    ftl_println!("msg-actions-dispatch-success", name, r#ref, n_inputs);

    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RunSelector {
    Id(i64),
    Number(i64),
}

fn parse_run_selector(raw: &str) -> eyre::Result<RunSelector> {
    let raw = raw.trim();
    if raw.is_empty() {
        ftl_bail!("msg-actions-run-invalid", run = raw);
    }

    if let Some(number) = raw.strip_prefix('#') {
        let number = number.parse::<i64>().map_err(|_| {
            eyre::eyre!(
                "{}",
                crate::ftl_format!("msg-actions-run-invalid", run = raw)
            )
        })?;
        return Ok(RunSelector::Number(number));
    }

    let id = raw.parse::<i64>().map_err(|_| {
        eyre::eyre!(
            "{}",
            crate::ftl_format!("msg-actions-run-invalid", run = raw)
        )
    })?;
    Ok(RunSelector::Id(id))
}

fn is_not_found(err: &ForgejoError) -> bool {
    matches!(
        err,
        ForgejoError::ApiError(forgejo_api::ApiError {
            kind: forgejo_api::ApiErrorKind::NotFound { .. },
            ..
        }) | ForgejoError::ApiError(forgejo_api::ApiError {
            kind: forgejo_api::ApiErrorKind::Other(StatusCode::NOT_FOUND),
            ..
        })
    )
}

fn is_unsupported_status(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED | StatusCode::NOT_IMPLEMENTED
    )
}

fn is_unsupported(err: &ForgejoError) -> bool {
    match err {
        ForgejoError::ApiError(forgejo_api::ApiError {
            kind: forgejo_api::ApiErrorKind::NotFound { .. },
            ..
        }) => true,
        ForgejoError::ApiError(forgejo_api::ApiError {
            kind: forgejo_api::ApiErrorKind::Other(status),
            ..
        }) => is_unsupported_status(*status),
        _ => false,
    }
}

fn job_has_steps(job: &ActionRunJob) -> bool {
    job.steps.as_ref().is_some_and(|steps| !steps.is_empty())
}

struct LoadedJobs {
    jobs: Vec<ActionRunJob>,
    steps_unsupported: bool,
}

async fn lookup_run_by_number(
    repo: &RepoName,
    api: &Forgejo,
    number: i64,
) -> eyre::Result<Option<ActionRun>> {
    let res = match api
        .list_action_runs(
            repo.owner(),
            repo.name(),
            ListActionRunsQuery {
                run_number: Some(number),
                ..Default::default()
            },
        )
        .await
    {
        Ok(res) => res,
        Err(e) if is_unsupported(&e) => ftl_bail!("msg-actions-unsupported-runs"),
        Err(e) => return Err(e.into()),
    };

    Ok(res
        .workflow_runs
        .unwrap_or_default()
        .into_iter()
        .find(|run| run.index_in_repo == Some(number) || run.id == Some(number)))
}

async fn resolve_run(repo: &RepoName, api: &Forgejo, raw: &str) -> eyre::Result<ActionRun> {
    match parse_run_selector(raw)? {
        RunSelector::Id(id) => match api.get_action_run(repo.owner(), repo.name(), id).await {
            Ok(run) => Ok(run),
            Err(e) if is_not_found(&e) => {
                lookup_run_by_number(repo, api, id).await?.ok_or_else(|| {
                    eyre::eyre!(
                        "{}",
                        crate::ftl_format!("msg-actions-run-not_found", run = raw)
                    )
                })
            }
            Err(e) if is_unsupported(&e) => ftl_bail!("msg-actions-unsupported-runs"),
            Err(e) => Err(e.into()),
        },
        RunSelector::Number(number) => {
            lookup_run_by_number(repo, api, number)
                .await?
                .ok_or_else(|| {
                    eyre::eyre!(
                        "{}",
                        crate::ftl_format!("msg-actions-run-not_found", run = raw)
                    )
                })
        }
    }
}

async fn load_jobs(
    repo: &RepoName,
    api: &Forgejo,
    run_id: i64,
    with_steps: bool,
) -> eyre::Result<LoadedJobs> {
    let jobs = match api
        .list_action_run_jobs(repo.owner(), repo.name(), run_id)
        .await
    {
        Ok(jobs) => jobs,
        Err(e) if is_unsupported(&e) => ftl_bail!("msg-actions-unsupported-jobs"),
        Err(e) => return Err(e.into()),
    };

    if !with_steps {
        return Ok(LoadedJobs {
            jobs,
            steps_unsupported: false,
        });
    }

    let mut detailed = Vec::with_capacity(jobs.len());
    let mut steps_unsupported = false;
    for job in jobs {
        let Some(job_id) = job.id else {
            detailed.push(job);
            continue;
        };
        if job_has_steps(&job) || steps_unsupported {
            detailed.push(job);
            continue;
        }

        match api
            .repo_get_action_job(repo.owner(), repo.name(), job_id)
            .await
        {
            Ok(detailed_job) => detailed.push(detailed_job),
            Err(e) if is_unsupported(&e) => {
                steps_unsupported = true;
                detailed.push(job);
            }
            Err(e) => return Err(e.into()),
        }
    }

    Ok(LoadedJobs {
        steps_unsupported: steps_unsupported && !detailed.iter().any(job_has_steps),
        jobs: detailed,
    })
}

fn status_symbol(status: Option<&str>) -> String {
    let SpecialRender {
        fancy,
        reset,
        bright_green,
        light_grey,
        bright_red,
        yellow,
        ..
    } = *crate::special_render();

    match status {
        x if !fancy => x.unwrap_or("?").to_owned(),
        // See: https://codeberg.org/forgejo/forgejo/src/commit/5380f23daba969057d9afc53c3dc746eca95188c/models/actions/status.go#L26
        Some("success") => format!("{bright_green}✓{reset}"),
        Some("cancelled") => format!("{light_grey}!{reset}"),
        Some("failure") => format!("{bright_red}×{reset}"),
        Some("waiting") => format!("{light_grey}{reset}"),
        Some("running") => format!("{yellow}●{reset}"),
        Some("skipped") => format!("{light_grey}{reset}"),
        Some("blocked") => format!("{bright_red}{reset}"),
        Some(status) => status.to_owned(),
        None => "?".to_owned(),
    }
}

fn format_duration(duration: Duration) -> String {
    duration.to_string()
}

fn run_duration(run: &ActionRun) -> Duration {
    if let (Some(start), Some(stop)) = (run.started, run.stopped) {
        stop - start
    } else if let (Some(start), Some(updated)) = (run.started, run.updated) {
        updated - start
    } else {
        Duration::default()
    }
}

fn print_job_line(job: &ActionRunJob) {
    let SpecialRender { bullet, .. } = *crate::special_render();
    let bullet = bullet.to_string();
    ftl_println!(
        "msg-actions-view-job",
        bullet,
        id = job.id.unwrap_or(0),
        status_sym = status_symbol(job.status.as_deref()),
        status = job.status.as_deref().unwrap_or("?"),
        name = job.name.as_deref().unwrap_or("?"),
        runs_on = job
            .runs_on
            .as_ref()
            .map(|labels| labels.join(","))
            .unwrap_or_else(|| "?".to_owned()),
        attempt = job.attempt.unwrap_or(0),
    );
}

fn print_job_steps(job: &ActionRunJob) {
    let SpecialRender { dash, .. } = *crate::special_render();
    let dash = dash.to_string();
    for step in job.steps.iter().flatten() {
        ftl_println!(
            "msg-actions-view-step",
            dash = dash.as_str(),
            number = step.number.unwrap_or(0),
            status_sym = status_symbol(step.status.as_deref()),
            status = step.status.as_deref().unwrap_or("?"),
            name = step.name.as_deref().unwrap_or("?"),
        );
    }
}

fn print_run_header(run: &ActionRun) {
    ftl_println!(
        "msg-actions-view-header",
        number = run.index_in_repo.unwrap_or(0),
        status_sym = status_symbol(run.status.as_deref()),
        status = run.status.as_deref().unwrap_or("?"),
        workflow = run.workflow_id.as_deref().unwrap_or("?"),
    );

    if let Some(title) = run.title.as_deref().filter(|title| !title.is_empty()) {
        ftl_println!("msg-actions-view-title", title);
    }

    ftl_println!("msg-actions-view-id", id = run.id.unwrap_or(0));
    ftl_println!(
        "msg-actions-view-event",
        event = run
            .event
            .as_deref()
            .or(run.trigger_event.as_deref())
            .unwrap_or("?")
    );
    ftl_println!(
        "msg-actions-view-ref",
        r#ref = run.prettyref.as_deref().unwrap_or("?")
    );
    ftl_println!(
        "msg-actions-view-sha",
        sha = run.commit_sha.as_deref().unwrap_or("?")
    );

    if let Some(user) = run
        .trigger_user
        .as_ref()
        .and_then(|user| user.login.as_deref())
    {
        ftl_println!("msg-actions-view-trigger", user);
    }

    if let Some(started) = run.started {
        ftl_println!("msg-actions-view-started", started = started.ftl());
    }

    ftl_println!(
        "msg-actions-view-duration",
        duration = format_duration(run_duration(run))
    );

    if let Some(url) = run.html_url.as_ref() {
        ftl_println!("msg-actions-view-url", url = url.as_str());
    }
}

async fn view_run(
    repo: &RepoName,
    api: &Forgejo,
    raw: &str,
    job_id: Option<i64>,
    logs: bool,
    step: Option<u32>,
    attempt: Option<i64>,
) -> eyre::Result<()> {
    let run = resolve_run(repo, api, raw).await?;
    let run_id = run.id.ok_or_eyre("server returned ActionRun without id")?;

    print_run_header(&run);
    println!();

    let loaded = load_jobs(repo, api, run_id, true).await?;
    let steps_unsupported = loaded.steps_unsupported;
    let jobs = if let Some(job_id) = job_id {
        let filtered: Vec<_> = loaded
            .jobs
            .into_iter()
            .filter(|job| job.id == Some(job_id))
            .collect();
        if filtered.is_empty() {
            ftl_bail!("msg-actions-job-not_found", job = job_id);
        }
        filtered
    } else {
        loaded.jobs
    };

    if jobs.is_empty() {
        if steps_unsupported {
            ftl_bail!("msg-actions-unsupported-steps");
        }
        ftl_println!("msg-actions-view-no_jobs");
        return Ok(());
    }

    ftl_println!("msg-actions-view-jobs-header");
    for job in &jobs {
        print_job_line(job);
        print_job_steps(job);
    }

    if logs {
        for job in &jobs {
            let Some(id) = job.id else {
                continue;
            };
            println!();
            ftl_println!(
                "msg-actions-logs-job-header",
                id,
                name = job.name.as_deref().unwrap_or("?")
            );
            print_job_logs(repo, api, id, step, attempt).await?;
        }
    }

    if steps_unsupported {
        ftl_bail!("msg-actions-unsupported-steps");
    }

    Ok(())
}

async fn view_jobs(repo: &RepoName, api: &Forgejo, raw: &str) -> eyre::Result<()> {
    let run = resolve_run(repo, api, raw).await?;
    let run_id = run.id.ok_or_eyre("server returned ActionRun without id")?;
    let loaded = load_jobs(repo, api, run_id, false).await?;

    if loaded.jobs.is_empty() {
        ftl_println!("msg-actions-view-no_jobs");
        return Ok(());
    }

    for job in &loaded.jobs {
        print_job_line(job);
    }

    Ok(())
}

async fn view_logs(
    repo: &RepoName,
    api: &Forgejo,
    job: Option<i64>,
    run: Option<&str>,
    out: Option<PathBuf>,
    step: Option<u32>,
    attempt: Option<i64>,
) -> eyre::Result<()> {
    match (job, run) {
        (Some(job), None) => print_job_logs(repo, api, job, step, attempt).await,
        (None, Some(run)) => {
            let run = resolve_run(repo, api, run).await?;
            let run_id = run.id.ok_or_eyre("server returned ActionRun without id")?;
            download_run_logs(repo, api, run_id, out).await
        }
        (Some(_), Some(_)) => ftl_bail!("msg-actions-logs-one_target"),
        (None, None) => ftl_bail!("msg-actions-logs-need_target"),
    }
}

async fn print_job_logs(
    repo: &RepoName,
    api: &Forgejo,
    job_id: i64,
    step: Option<u32>,
    attempt: Option<i64>,
) -> eyre::Result<()> {
    let bytes = match api
        .repo_get_action_job_logs(
            repo.owner(),
            repo.name(),
            job_id,
            RepoGetActionJobLogsQuery {
                attempt,
                step,
                ..Default::default()
            },
        )
        .await
    {
        Ok(bytes) => bytes,
        Err(e) if is_unsupported(&e) => ftl_bail!("msg-actions-unsupported-logs"),
        Err(e) => return Err(e.into()),
    };

    let mut stdout = std::io::stdout();
    stdout.write_all(&bytes)?;
    if !bytes.ends_with(b"\n") {
        stdout.write_all(b"\n")?;
    }
    stdout.flush()?;
    Ok(())
}

async fn download_run_logs(
    repo: &RepoName,
    api: &Forgejo,
    run_id: i64,
    out: Option<PathBuf>,
) -> eyre::Result<()> {
    let bytes = match api
        .repo_get_action_run_logs(repo.owner(), repo.name(), run_id)
        .await
    {
        Ok(bytes) => bytes,
        Err(e) if is_unsupported(&e) => ftl_bail!("msg-actions-unsupported-logs"),
        Err(e) => return Err(e.into()),
    };
    let path = out.unwrap_or_else(|| PathBuf::from(format!("run-{run_id}-logs.zip")));
    tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
        .await?
        .write_all(bytes.as_ref())
        .await?;
    ftl_println!("msg-actions-logs-run-saved", file = path.to_string_lossy());
    Ok(())
}

struct DisplayActionVariable {
    name: String,
    data: String,
    owner_id: Option<i64>,
    repo_id: Option<i64>,
    verbose: bool,
}

impl DisplayActionVariable {
    fn new(value: ActionVariable, verbose: bool) -> eyre::Result<Self> {
        Ok(Self {
            name: value
                .name
                .ok_or_eyre("Server returned ActionVariable without name?!")?,
            // The API usually (always?) returns Some("") here. The page on variables also notes
            // that their value cannot be read by other means than being passed to a CI job.
            data: value.data.unwrap_or_default(),
            owner_id: value.owner_id,
            repo_id: value.repo_id,
            verbose,
        })
    }
}

impl Display for DisplayActionVariable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.verbose {
            write!(
                f,
                "({}, {}) ",
                crate::DisplayOptional(self.owner_id, "?"),
                crate::DisplayOptional(self.repo_id, "?"),
            )?;
        }

        write!(f, "{}", self.name)?;

        if !self.data.is_empty() {
            write!(f, " = {}", self.data)?;
        }

        Ok(())
    }
}

fn parse_dispatch_kvs(s: &str) -> eyre::Result<(String, String)> {
    let eq_idx = s
        .find('=')
        .ok_or_eyre("Input argument does not contain a '=' character!")?;

    Ok((s[..eq_idx].to_string(), s[eq_idx + 1..].to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn parse_run_selector_id() {
        assert_eq!(parse_run_selector("12345").unwrap(), RunSelector::Id(12345));
        assert_eq!(parse_run_selector(" 7 ").unwrap(), RunSelector::Id(7));
    }

    #[test]
    fn parse_run_selector_number() {
        assert_eq!(parse_run_selector("#12").unwrap(), RunSelector::Number(12));
        assert_eq!(parse_run_selector("  #3").unwrap(), RunSelector::Number(3));
    }

    #[test]
    fn parse_run_selector_rejects_empty_and_non_numeric() {
        assert!(parse_run_selector("").is_err());
        assert!(parse_run_selector("#").is_err());
        assert!(parse_run_selector("ci.yml").is_err());
    }

    #[test]
    fn clap_accepts_view_jobs_and_logs() {
        crate::App::try_parse_from(["fj", "actions", "view", "#12"]).unwrap();
        crate::App::try_parse_from(["fj", "actions", "view", "99", "--logs", "--job", "4"])
            .unwrap();
        crate::App::try_parse_from(["fj", "actions", "jobs", "99"]).unwrap();
        crate::App::try_parse_from(["fj", "actions", "logs", "--job", "4"]).unwrap();
        crate::App::try_parse_from(["fj", "actions", "logs", "--run", "#12", "--out", "x.zip"])
            .unwrap();
    }

    #[test]
    fn unsupported_status_covers_missing_endpoints() {
        assert!(is_unsupported_status(StatusCode::NOT_FOUND));
        assert!(is_unsupported_status(StatusCode::METHOD_NOT_ALLOWED));
        assert!(is_unsupported_status(StatusCode::NOT_IMPLEMENTED));
        assert!(!is_unsupported_status(StatusCode::FORBIDDEN));
        assert!(!is_unsupported_status(StatusCode::INTERNAL_SERVER_ERROR));
    }
}
