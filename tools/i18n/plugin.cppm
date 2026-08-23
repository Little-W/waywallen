export module waywallen.i18n.plugin;

import rstd;

export namespace waywallen::i18n
{

enum class ExitCode : int
{
    Success = 0,
    Usage   = 2,
    Plugin  = 3,
    Source  = 4,
    Catalog = 5,
    Io      = 6,
};

enum class Mode
{
    Update,
    Check,
};

struct Request {
    Mode                                     mode;
    rstd::path::PathBuf                      plugin;
    rstd::prelude::Vec<rstd::string::String> locales;
};

auto execute(const Request& request) -> ExitCode;

} // namespace waywallen::i18n
