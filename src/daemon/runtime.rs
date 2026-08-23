use std::future::Future;
use std::sync::Arc;

use super::DaemonContext;

/// Spawn the `waywallen-ui` subprocess fire-and-forget.
/// The UI reads the WS port from the Daemon1 DBus interface.
pub(crate) fn spawn_ui(state: &DaemonContext) -> bool {
    spawn_ui_with_token(state, "")
}

/// Raise an existing UI if present, otherwise spawn one.
/// Uses a pending SNI xdg-activation token when the tray host provided one
/// (Wayland). On X11 the token is empty and Raise still restores via Qt.
pub(crate) async fn open_or_raise_ui(state: &DaemonContext) -> bool {
    let token = state
        .xdg_activation_token
        .lock()
        .unwrap()
        .take()
        .unwrap_or_default();
    if try_raise_ui(state, &token).await {
        return true;
    }
    spawn_ui_with_token(state, &token)
}

async fn try_raise_ui(state: &DaemonContext, token: &str) -> bool {
    let Some(conn) = state.dbus_conn.lock().unwrap().clone() else {
        return false;
    };
    let proxy = match zbus::Proxy::new(
        conn.as_ref(),
        "org.waywallen.waywallen.UI",
        "/org/waywallen/waywallen/UI",
        "org.waywallen.waywallen.UI1",
    )
    .await
    {
        Ok(proxy) => proxy,
        Err(_) => return false,
    };
    proxy.call_method("Raise", &(token,)).await.is_ok()
}

fn spawn_ui_with_token(state: &DaemonContext, token: &str) -> bool {
    let ui_bin = match state.ui_path.lock().unwrap().clone() {
        Some(path) => path,
        None => return false,
    };
    log::info!("launching ui: {}", ui_bin.display());
    let mut cmd = std::process::Command::new(&ui_bin);
    if !token.is_empty() {
        cmd.env("XDG_ACTIVATION_TOKEN", token);
    }
    match cmd.spawn() {
        Ok(child) => {
            log::info!("ui pid: {}", child.id());
            true
        }
        Err(error) => {
            log::warn!("failed to launch ui {}: {error}", ui_bin.display());
            false
        }
    }
}

pub(super) async fn run_until_shutdown<F>(
    state: Arc<DaemonContext>,
    websocket: F,
    dbus: Arc<zbus::Connection>,
) -> anyhow::Result<()>
where
    F: Future<Output = anyhow::Result<()>>,
{
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::pin!(websocket);

    let websocket_exited = tokio::select! {
        result = &mut websocket => {
            if let Err(error) = result {
                log::error!("ws server exited with error: {error}");
            }
            true
        }
        _ = tokio::signal::ctrl_c() => {
            log::info!("SIGINT received, shutting down");
            false
        }
        _ = sigterm.recv() => {
            log::info!("SIGTERM received, shutting down");
            false
        }
        _ = async {
            let mut receiver = state.shutdown_subscribe();
            let _ = receiver.wait_for(|requested| *requested).await;
        } => {
            log::info!("shutdown requested via D-Bus");
            false
        }
    };

    state.shutdown_now();
    if !websocket_exited {
        if let Err(error) = websocket.await {
            log::warn!("ws server shutdown failed: {error}");
        }
    }
    crate::system::tray::ensure_stopped(&state).await;
    if let Err(error) = state.qr_login.cancel_all_and_wait().await {
        log::warn!("QR login shutdown cleanup failed: {error:#}");
    }
    state.playlists.shutdown().await;
    state.tasks.wait_stopped().await;
    let renderer_ids = state
        .router
        .snapshot_renderers()
        .await
        .into_iter()
        .map(|renderer| renderer.id)
        .collect::<Vec<_>>();
    state
        .router
        .stop_renderers_orderly(&renderer_ids, std::time::Duration::from_secs(1))
        .await;
    state.renderer_manager.shutdown().await;
    state.settings.stop_writer().await;
    state.settings.flush_now().await;

    if let Err(error) = crate::system::dbus::emit_shutting_down(&dbus).await {
        log::warn!("DBus ShuttingDown emit failed: {error}");
    }
    Ok(())
}
