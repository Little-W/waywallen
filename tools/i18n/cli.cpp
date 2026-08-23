module;

#include <stdio.h>
#include <string.h>

module waywallen.i18n.cli;

import rstd;
import rstd.argparse;
import waywallen.i18n.plugin;

namespace waywallen::i18n
{

using namespace rstd::argparse;
using namespace rstd::literals;
using namespace rstd::prelude;
using ::alloc::string::String;
using ::alloc::vec::Vec;

struct CommandArguments {
    CommandKey     command;
    ArgKey<String> plugin;
    ArgKey<String> locale;
};

void write_output(ref<str> text, OutputTarget::Tag target) {
    FILE* stream = target == OutputTarget::Tag::Stderr ? stderr : stdout;
    if (! text.is_empty()) (void)::fwrite(text.data(), 1, text.len().to_primitive(), stream);
}

auto argv_values(int argc, char** argv) -> Vec<rstd::ffi::OsString> {
    auto values = Vec<rstd::ffi::OsString>::with_capacity(static_cast<usize>(argc));
    for (int index = 0; index < argc; ++index) {
        auto bytes = slice<u8>::from_raw_parts(reinterpret_cast<const byte*>(argv[index]),
                                               usize(::strlen(argv[index])));
        values.push(
            rstd::ffi::OsString::from(ref<rstd::ffi::OsStr>::from_encoded_bytes_unchecked(bytes)));
    }
    return values;
}

auto command_arguments(ref<str> name, ref<str> about, ref<str> locale_help, bool locale_required)
    -> rstd::tuple<Command, CommandArguments> {
    auto command = Command::make(name);
    command.about(about);
    auto command_key = command.key();
    auto plugin = command.add_arg(Arg<String>::value("plugin"_str, string_parser())
                                      .long_name("plugin"_str)
                                      .value_name("DIR"_str)
                                      .help("Plugin root containing plugin.toml and files.txt"_str)
                                      .required());
    auto locale_argument = Arg<String>::value("locale"_str, string_parser())
                               .long_name("locale"_str)
                               .value_name("TAG"_str)
                               .help(locale_help)
                               .append();
    if (locale_required) locale_argument.required();
    auto locale = command.add_arg(rstd::move(locale_argument));
    return { rstd::move(command), CommandArguments { command_key, plugin, locale } };
}

auto get_one(const Matches& matches, const ArgKey<String>& key) -> Option<ref<String>> {
    auto value = matches.get_one(key);
    if (value.is_err()) return None();
    return rstd::move(value).unwrap_unchecked();
}

auto make_request(Mode mode, const Matches& matches, const CommandArguments& arguments)
    -> Option<Request> {
    auto plugin = get_one(matches, arguments.plugin);
    if (plugin.is_none()) return None();
    auto locales = Vec<String>::make();
    auto values  = matches.get_many(arguments.locale);
    if (values.is_err()) return None();
    if (values->is_some()) {
        auto iterator = rstd::move(**values);
        while (auto value = iterator.next()) locales.push((*value)->clone());
    }
    return Some(
        Request { mode, rstd::path::PathBuf::from((**plugin).as_str()), rstd::move(locales) });
}

auto run(int argc, char** argv) -> int {
    auto [update_command, update_arguments] =
        command_arguments("update"_str,
                          "Extract Lua messages and atomically update one locale catalog"_str,
                          "Locale to update; exactly one is required"_str,
                          true);
    auto [check_command, check_arguments] =
        command_arguments("check"_str,
                          "Validate Lua sources and synchronized locale catalogs"_str,
                          "Locale to check; repeat to select several, or omit to check all"_str,
                          false);

    auto command = Command::make("waywallen-i18n"_str);
    command.about("Maintain static Lua translation catalogs for a Waywallen plugin"_str);
    command.version("0.3.5"_str);
    command.require_subcommand();
    command.add_subcommand(rstd::move(update_command));
    command.add_subcommand(rstd::move(check_command));

    auto built = rstd::move(command).build();
    if (built.is_err()) {
        auto text = rstd::format("waywallen-i18n: invalid CLI definition: {}\n",
                                 rstd::move(built).unwrap_err_unchecked());
        write_output(text.as_str(), OutputTarget::Tag::Stderr);
        return static_cast<int>(ExitCode::Usage);
    }
    auto parser = rstd::move(built).unwrap_unchecked();
    auto parsed = parser.parse_from(argv_values(argc, argv));
    if (parsed.is_err()) {
        auto report = parser.render_error(rstd::move(parsed).unwrap_err_unchecked());
        write_output(report.text(), report.target());
        return report.exit_code().to_primitive();
    }
    auto outcome = rstd::move(parsed).unwrap_unchecked();
    if (outcome.is_Display()) {
        const auto& request = outcome.as_Display().request;
        write_output(request.text(), request.target());
        return request.exit_code().to_primitive();
    }

    auto matches = rstd::move(outcome).as_Parsed().value;
    if (auto selected = matches.subcommand_matches(update_arguments.command); selected.is_some()) {
        auto request = make_request(Mode::Update, **selected, update_arguments);
        if (request.is_none()) return static_cast<int>(ExitCode::Usage);
        return static_cast<int>(execute(*request));
    }
    if (auto selected = matches.subcommand_matches(check_arguments.command); selected.is_some()) {
        auto request = make_request(Mode::Check, **selected, check_arguments);
        if (request.is_none()) return static_cast<int>(ExitCode::Usage);
        return static_cast<int>(execute(*request));
    }
    return static_cast<int>(ExitCode::Usage);
}

} // namespace waywallen::i18n
