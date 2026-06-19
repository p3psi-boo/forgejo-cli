use std::{collections::BTreeMap, fmt::Display};

use clap::{Args, Subcommand};
use eyre::OptionExt;
use forgejo_api::{
    structs::{
        ActionVariable, CreateOrUpdateSecretOption, CreateVariableOption, UpdateVariableOption,
    },
    Forgejo, ForgejoError,
};
use hyper::StatusCode;
use time::Duration;

use crate::{
    ftl_bail, ftl_eprintln, ftl_println,
    repo::{RepoArg, RepoInfo, RepoName},
    SpecialRender,
};

#[derive(Args, Clone, Debug)]
pub struct ActionsCommand {
    /// The local git remote that points to the repo to operate on
    #[clap(long, short = 'R', global = true)]
    remote: Option<String>,

    /// The repo to operate on
    #[clap(long, short, global = true)]
    repo: Option<RepoArg>,

    #[clap(subcommand)]
    command: ActionsSubcommand,
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsSubcommand {
    /// List the tasks on a repo
    Tasks {
        /// The page to show. One page always includes up to 20 tasks.
        #[clap(long, short, default_value = "1")]
        page: u32,
    },

    /// List and manage variables
    Variables {
        #[clap(subcommand)]
        command: ActionsVariablesSubcommmand,
    },

    Secrets {
        #[clap(subcommand)]
        command: ActionsSecretsSubcommmand,
    },

    /// Dispatch a workflow
    Dispatch {
        /// Name of the workflow to dispatch
        name: String,

        /// Git revision to dispatch the workflow on
        r#ref: String,

        #[clap(long, short = 'I', value_parser = parse_dispatch_kvs)]
        inputs: Vec<(String, String)>,
    },

    /// List the jobs in an action run (Forgejo v16+, forgejo/forgejo#12666)
    Jobs {
        /// The action run id
        run: i64,
    },

    /// View the logs of an action run or job (Forgejo v16+, forgejo/forgejo#12666)
    Logs {
        /// Print a single job's logs as plain text. Takes precedence over --run.
        ///
        /// Use `jobs` to find the job id.
        #[clap(long)]
        job: Option<i64>,

        /// Download all jobs' logs for a run as a zip archive.
        #[clap(long)]
        run: Option<i64>,

        /// File to write the run's zip archive to (default: run-<id>-logs.zip).
        /// Only meaningful with --run.
        #[clap(long)]
        out: Option<String>,
    },
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsVariablesSubcommmand {
    /// List variables
    List {
        /// Also print owner_id and repo_id
        #[clap(long, short)]
        verbose: bool,
    },

    /// Create a new variable
    Create {
        /// The name of the new variable
        name: String,

        /// The data to save into the variable. Omit to invoke editor.
        data: Option<String>,

        /// Override existing variables
        #[clap(long, short)]
        force: bool,
    },

    Delete {
        /// The variable to delete
        name: String,
    },
}

#[derive(Subcommand, Clone, Debug)]
pub enum ActionsSecretsSubcommmand {
    /// List secrets
    List,

    /// Create a new secret
    Create {
        /// The name of the new secret
        name: String,

        /// The data to save into the secret.
        data: String,
    },

    Delete {
        /// The secret to delete
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

            ActionsSubcommand::Jobs { run } => list_jobs(repo, &api, run).await?,

            ActionsSubcommand::Logs { job, run, out } => {
                view_logs(repo, &api, job, run, out).await?
            }
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
        fancy,
        reset,

        bold,
        bright_green,
        light_grey,
        bright_red,
        yellow,
        bright_blue,
        ..
    } = *crate::special_render();

    for task in res.workflow_runs.unwrap_or_default() {
        let task_sym = match task.status.as_deref() {
            // Don't use symbols when we're not in fancy mode.
            x if !fancy => x.unwrap_or("?"),

            // See: https://codeberg.org/forgejo/forgejo/src/commit/5380f23daba969057d9afc53c3dc746eca95188c/models/actions/status.go#L26
            Some("success") => &format!("{bright_green}✓{reset}"),
            Some("cancelled") => &format!("{light_grey}!{reset}"),
            Some("failure") => &format!("{bright_red}×{reset}"),
            Some("waiting") => &format!("{light_grey}{reset}"),
            Some("running") => &format!("{yellow}●{reset}"),
            Some("skipped") => &format!("{light_grey}{reset}"),
            Some("blocked") => &format!("{bright_red}{reset}"),
            Some(x) => x,
            None => "?",
        };

        let sha = task.head_sha.unwrap_or_default();
        let sha = if sha.len() > 10 { &sha[0..10] } else { &sha };

        let time = if let (Some(end), Some(start)) = (task.updated_at, task.run_started_at) {
            end - start
        } else {
            Duration::default()
        };

        println!(
            "#{bold}{}{reset} ({bright_blue}{}{reset}) {} {} {bright_green}{}{reset} ({}): {yellow}{}{reset}",
            task.run_number.unwrap_or(0),
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

async fn view_logs(
    repo: &RepoName,
    api: &Forgejo,
    job: Option<i64>,
    run: Option<i64>,
    out: Option<String>,
) -> eyre::Result<()> {
    use std::io::Write as _;
    if let Some(job_id) = job {
        let bytes = api
            .repo_get_action_job_logs(repo.owner(), repo.name(), job_id)
            .await?;
        std::io::stdout().write_all(&bytes)?;
        return Ok(());
    }
    if let Some(run_id) = run {
        let bytes = api
            .repo_get_action_run_logs(repo.owner(), repo.name(), run_id)
            .await?;
        let path = out.unwrap_or_else(|| format!("run-{run_id}-logs.zip"));
        std::fs::write(&path, &bytes)?;
        println!(
            "wrote {} bytes ({} jobs) to {path}",
            bytes.len(),
            zip_entry_count(&bytes).unwrap_or(0)
        );
        return Ok(());
    }
    eyre::bail!("must specify --job <ID> or --run <ID>");
}

async fn list_jobs(repo: &RepoName, api: &Forgejo, run: i64) -> eyre::Result<()> {
    let jobs = api
        .list_action_run_jobs(repo.owner(), repo.name(), run)
        .await?;
    if jobs.is_empty() {
        println!("no jobs");
        return Ok(());
    }
    for j in jobs {
        println!(
            "#{} {} [{}] runs_on:{}",
            j.id.unwrap_or(0),
            j.name.unwrap_or_default(),
            j.status.unwrap_or_default(),
            j.runs_on.unwrap_or_default().join(","),
        );
    }
    Ok(())
}

/// Count entries in a zip archive by reading the End-of-Central-Directory
/// record, without pulling in a zip crate dependency.
fn zip_entry_count(zip: &[u8]) -> Option<u16> {
    let eocd = b"PK\x05\x06";
    let idx = zip.windows(4).rposition(|w| w == eocd)?;
    // [sig 4][disk 2][disk_cd 2][entries_this_disk 2][entries_total 2]
    let off = idx + 10;
    if off + 2 > zip.len() {
        return None;
    }
    Some(u16::from_le_bytes([zip[off], zip[off + 1]]))
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
