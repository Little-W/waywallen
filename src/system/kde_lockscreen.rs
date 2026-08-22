use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::tasks;
use crate::DaemonContext;

const WALLPAPER_PLUGIN_ID: &str = "org.waywallen.kde";
const WATCH_INTERVAL: Duration = Duration::from_secs(2);

fn config_path() -> Option<PathBuf> {
    if let Some(config_home) = std::env::var_os("XDG_CONFIG_HOME") {
        return Some(PathBuf::from(config_home).join("kscreenlockerrc"));
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config/kscreenlockerrc"))
}

fn waywallen_selected(config: &str) -> bool {
    let mut in_greeter = false;
    for raw_line in config.lines() {
        let line = raw_line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_greeter = line == "[Greeter]";
            continue;
        }
        if !in_greeter || line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() == "WallpaperPlugin" && value.trim() == WALLPAPER_PLUGIN_ID {
            return true;
        }
    }
    false
}

fn enabled() -> bool {
    config_path()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .is_some_and(|config| waywallen_selected(&config))
}

/// Keep a configuration target visible only while KDE is configured to use
/// Waywallen for the lock screen. The target has no transport, so it cannot
/// allocate buffers or keep a renderer active while the session is unlocked.
pub(crate) fn spawn(app: Arc<DaemonContext>) {
    let shutdown = app.shutdown_subscribe();
    let task_app = app.clone();
    app.tasks.spawn_async(
        tasks::TaskKind::Service,
        "service/kde-lockscreen-target",
        async move {
            let mut target_id = None;
            let mut ticker = tokio::time::interval(WATCH_INTERVAL);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut shutdown = shutdown;

            loop {
                tokio::select! {
                    _ = ticker.tick() => match (enabled(), target_id) {
                        (true, None) => match task_app.router.register_kde_lockscreen_target().await {
                            Ok(handle) => {
                                target_id = Some(handle.id);
                                log::info!("KDE lock-screen configuration enabled");
                            }
                            Err(error) => log::warn!("register KDE lock-screen target: {error}"),
                        },
                        (false, Some(id)) => {
                            task_app.router.unregister_display(id).await;
                            target_id = None;
                            log::info!("KDE lock-screen configuration disabled");
                        }
                        _ => {}
                    },
                    changed = shutdown.changed() => {
                        if changed.is_err() || *shutdown.borrow() {
                            return Ok(());
                        }
                    }
                }
            }
        },
    );
}

#[cfg(test)]
mod tests {
    use super::waywallen_selected;

    #[test]
    fn recognizes_only_the_greeter_wallpaper_plugin() {
        assert!(waywallen_selected(
            "[Greeter]\nWallpaperPlugin=org.waywallen.kde\n[Daemon]\nWallpaperPlugin=other"
        ));
        assert!(!waywallen_selected(
            "[Greeter]\nWallpaperPlugin=org.kde.image"
        ));
        assert!(!waywallen_selected(
            "[Other]\nWallpaperPlugin=org.waywallen.kde"
        ));
    }
}
