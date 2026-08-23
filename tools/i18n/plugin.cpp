module;

#include <stdio.h>

module waywallen.i18n.plugin;

import luato.i18n;
import rstd;
import rstd.toml;

namespace waywallen::i18n
{

using namespace rstd::literals;
using namespace rstd::prelude;
using ::alloc::collections::BTreeMap;
using ::alloc::string::String;
using ::alloc::vec::Vec;

struct Failure {
    ExitCode code;
    String   message;
};

template<typename T>
using ToolResult = Result<T, Failure>;

struct Project {
    rstd::path::PathBuf     root;
    String                  id;
    String                  catalog_directory;
    BTreeMap<String, empty> declared_files;
};

struct OwnedSource {
    String logical_path;
    String text;
};

auto with_newline(String message) -> String {
    if (! message.as_str().ends_with("\n"_str)) message.push_ascii('\n');
    return message;
}

auto failure(ExitCode code, String message) -> Failure {
    return Failure { code, with_newline(rstd::move(message)) };
}

auto path_text(ref<rstd::path::Path> path) -> String { return path.to_string_lossy(); }

template<typename Error>
auto io_failure(ref<rstd::path::Path> path, const Error& error) -> Failure {
    return failure(ExitCode::Io, rstd::format("{}: error[io]: {}", path, error));
}

void write_text(FILE* stream, ref<str> text) {
    if (text.is_empty()) return;
    (void)::fwrite(text.data(), 1, text.len().to_primitive(), stream);
}

auto emit(Failure value) -> ExitCode {
    write_text(stderr, value.message.as_str());
    return value.code;
}

void emit_diagnostic(const luato::i18n::Diagnostic& diagnostic) {
    auto text = rstd::format("{}:{}:{}: error[{}]: {}\n",
                             diagnostic.source.as_str(),
                             diagnostic.position.line,
                             diagnostic.position.column,
                             luato::i18n::code_name(diagnostic.code),
                             diagnostic.message.as_str());
    write_text(stderr, text.as_str());
    for (const auto& related : diagnostic.related) {
        auto line = rstd::format("  {}:{}:{}: note: {}\n",
                                 related.source.as_str(),
                                 related.position.line,
                                 related.position.column,
                                 related.message.as_str());
        write_text(stderr, line.as_str());
    }
}

auto join_path(ref<rstd::path::Path> base, ref<str> child) -> rstd::path::PathBuf {
    auto component = rstd::path::PathBuf::from(child);
    return rstd::path::PathBuf::from(base).join(component.as_path());
}

auto normalize_relative(ref<str> value, ref<str> owner) -> ToolResult<String> {
    auto input = rstd::path::PathBuf::from(value);
    if (! input.as_path().is_safe_relative()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[unsafe-plugin-path]: '{}' is not a safe "
                                        "relative path",
                                        owner,
                                        value)));
    }

    auto normalized = String::make();
    auto components = input.as_path().components();
    while (auto component = components.next()) {
        if (! component->is_normal()) continue;
        auto text = component->as_os_str().to_str();
        if (text.is_none()) {
            return Err(
                failure(ExitCode::Plugin,
                        rstd::format("{}: error[unsafe-plugin-path]: path is not UTF-8", owner)));
        }
        if (! normalized.is_empty()) normalized.push_ascii('/');
        normalized.push_str(*text);
    }
    if (normalized.is_empty()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[unsafe-plugin-path]: path is empty", owner)));
    }
    return Ok(rstd::move(normalized));
}

auto read_text_file(ref<rstd::path::Path> path) -> ToolResult<String> {
    auto contents = rstd::fs::read_to_string(path);
    if (contents.is_err()) return Err(io_failure(path, contents.unwrap_err()));
    return Ok(rstd::move(contents).unwrap_unchecked());
}

auto required_string(const rstd::toml::Value& table, ref<str> key, ref<rstd::path::Path> manifest,
                     ref<str> owner) -> ToolResult<String> {
    auto value = table.get(key);
    if (value.is_none() || ! (*value)->is_string()) {
        return Err(failure(
            ExitCode::Plugin,
            rstd::format(
                "{}: error[plugin-manifest]: '{}.{}' must be a string", manifest, owner, key)));
    }
    return Ok(String::make(*(*value)->as_str()));
}

auto parse_declared_files(ref<str> document, ref<rstd::path::Path> files_path)
    -> ToolResult<BTreeMap<String, empty>> {
    auto declared = BTreeMap<String, empty>::make();
    auto begin    = usize {};
    while (begin <= document.len()) {
        auto end = begin;
        while (end < document.len() && document.as_bytes()[end] != u8('\n')) ++end;
        auto line = document.get(begin, end).unwrap().trim_ascii();
        if (! line.is_empty()) {
            const bool relevant   = line.ends_with(".lua"_str) || line.ends_with(".json"_str);
            auto       normalized = normalize_relative(line, "files.txt"_str);
            if (normalized.is_err()) {
                if (relevant) return Err(rstd::move(normalized).unwrap_err_unchecked());
            } else {
                auto path = rstd::move(normalized).unwrap_unchecked();
                if (declared.insert(path.clone(), empty {}).is_some()) {
                    return Err(failure(ExitCode::Plugin,
                                       rstd::format("{}: error[plugin-files]: duplicate entry '{}'",
                                                    files_path,
                                                    path.as_str())));
                }
            }
        }
        if (end == document.len()) break;
        begin = end + usize(1);
    }
    return Ok(rstd::move(declared));
}

auto load_project(ref<rstd::path::Path> requested_root) -> ToolResult<Project> {
    auto canonical_root = rstd::fs::canonicalize(requested_root);
    if (canonical_root.is_err())
        return Err(io_failure(requested_root, canonical_root.unwrap_err()));
    auto root = rstd::move(canonical_root).unwrap_unchecked();

    auto root_metadata = rstd::fs::metadata(root.as_path());
    if (root_metadata.is_err()) return Err(io_failure(root.as_path(), root_metadata.unwrap_err()));
    if (! root_metadata->is_dir()) {
        return Err(
            failure(ExitCode::Plugin,
                    rstd::format("{}: error[plugin-root]: expected a directory", root.as_path())));
    }

    auto manifest_path = join_path(root.as_path(), "plugin.toml"_str);
    auto manifest_text = read_text_file(manifest_path.as_path());
    if (manifest_text.is_err()) return Err(rstd::move(manifest_text).unwrap_err_unchecked());
    auto parsed = rstd::toml::from_str(manifest_text->as_str());
    if (parsed.is_err()) {
        auto error = rstd::move(parsed).unwrap_err_unchecked();
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}:{}:{}: error[plugin-manifest]: {}",
                                        manifest_path.as_path(),
                                        error.line(),
                                        error.column(),
                                        error)));
    }
    auto document = rstd::move(parsed).unwrap_unchecked();
    auto plugin   = document.get("plugin"_str);
    if (plugin.is_none() || ! (*plugin)->is_table()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[plugin-manifest]: missing [plugin] table",
                                        manifest_path.as_path())));
    }
    auto id = required_string(**plugin, "id"_str, manifest_path.as_path(), "plugin"_str);
    if (id.is_err()) return Err(rstd::move(id).unwrap_err_unchecked());
    if (id->is_empty()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[plugin-manifest]: plugin.id cannot be empty",
                                        manifest_path.as_path())));
    }

    auto i18n = (*plugin)->get("i18n"_str);
    if (i18n.is_none() || ! (*i18n)->is_table()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[plugin-manifest]: missing [plugin.i18n] table",
                                        manifest_path.as_path())));
    }
    auto directory =
        required_string(**i18n, "directory"_str, manifest_path.as_path(), "plugin.i18n"_str);
    if (directory.is_err()) return Err(rstd::move(directory).unwrap_err_unchecked());
    auto normalized_directory =
        normalize_relative(directory->as_str(), "plugin.i18n.directory"_str);
    if (normalized_directory.is_err()) {
        return Err(rstd::move(normalized_directory).unwrap_err_unchecked());
    }

    auto files_path = join_path(root.as_path(), "files.txt"_str);
    auto files_text = read_text_file(files_path.as_path());
    if (files_text.is_err()) return Err(rstd::move(files_text).unwrap_err_unchecked());
    auto declared = parse_declared_files(files_text->as_str(), files_path.as_path());
    if (declared.is_err()) return Err(rstd::move(declared).unwrap_err_unchecked());

    return Ok(Project { rstd::move(root),
                        rstd::move(id).unwrap_unchecked(),
                        rstd::move(normalized_directory).unwrap_unchecked(),
                        rstd::move(declared).unwrap_unchecked() });
}

auto validate_owned_file(const Project& project, ref<str> logical)
    -> ToolResult<rstd::path::PathBuf> {
    auto path      = join_path(project.root.as_path(), logical);
    auto canonical = rstd::fs::canonicalize(path.as_path());
    if (canonical.is_err()) return Err(io_failure(path.as_path(), canonical.unwrap_err()));
    auto owned = rstd::move(canonical).unwrap_unchecked();
    if (! owned.as_path().starts_with(project.root.as_path())) {
        return Err(failure(
            ExitCode::Plugin,
            rstd::format("{}: error[unsafe-plugin-path]: path escapes plugin root", logical)));
    }
    auto metadata = rstd::fs::metadata(owned.as_path());
    if (metadata.is_err()) return Err(io_failure(owned.as_path(), metadata.unwrap_err()));
    if (! metadata->is_file()) {
        return Err(
            failure(ExitCode::Plugin,
                    rstd::format("{}: error[plugin-files]: expected a regular file", logical)));
    }
    return Ok(rstd::move(owned));
}

auto load_sources(const Project& project) -> ToolResult<Vec<OwnedSource>> {
    auto sources        = Vec<OwnedSource>::make();
    auto canonical_seen = BTreeMap<String, empty>::make();
    for (auto item : project.declared_files.iter()) {
        auto [logical, unused] = item;
        (void)unused;
        if (! logical->as_str().ends_with(".lua"_str)) continue;
        auto actual = validate_owned_file(project, logical->as_str());
        if (actual.is_err()) return Err(rstd::move(actual).unwrap_err_unchecked());
        auto canonical_key = path_text(actual->as_path());
        if (canonical_seen.insert(rstd::move(canonical_key), empty {}).is_some()) {
            return Err(failure(
                ExitCode::Plugin,
                rstd::format("{}: error[plugin-files]: duplicate Lua file", logical->as_str())));
        }
        auto text = read_text_file(actual->as_path());
        if (text.is_err()) return Err(rstd::move(text).unwrap_err_unchecked());
        sources.push(OwnedSource { logical->clone(), rstd::move(text).unwrap_unchecked() });
    }
    return Ok(rstd::move(sources));
}

auto extract_sources(const Vec<OwnedSource>& owned) -> ToolResult<luato::i18n::Extraction> {
    auto sources = Vec<luato::i18n::SourceFile>::with_capacity(owned.len());
    for (const auto& source : owned) {
        sources.push(luato::i18n::SourceFile { rstd::parse::SourceId(source.logical_path.clone()),
                                               source.text.as_str().as_bytes() });
    }

    auto callee = Vec<String>::make();
    callee.push(String::make("W"_str));
    callee.push(String::make("I18n"_str));
    callee.push(String::make("tr"_str));
    auto options   = luato::i18n::ExtractionOptions { luato::i18n::CallSpec {
        rstd::move(callee),
        usize {},
        usize(1),
        usize(2),
        String::make("TRANSLATORS:"_str),
        Some(String::make("W"_str)),
    } };
    auto extracted = luato::i18n::extract(sources.as_slice(), options);
    if (extracted.is_err()) {
        emit_diagnostic(extracted.unwrap_err());
        return Err(failure(ExitCode::Source, String::make()));
    }
    return Ok(rstd::move(extracted).unwrap_unchecked());
}

auto catalog_logical_path(const Project& project, ref<str> locale) -> ToolResult<String> {
    auto candidate = rstd::format("{}/{}.json", project.catalog_directory.as_str(), locale);
    return normalize_relative(candidate.as_str(), "catalog"_str);
}

auto catalog_directory(const Project& project, bool create) -> ToolResult<rstd::path::PathBuf> {
    auto path   = join_path(project.root.as_path(), project.catalog_directory.as_str());
    auto exists = rstd::fs::exists(path.as_path());
    if (exists.is_err()) return Err(io_failure(path.as_path(), exists.unwrap_err()));
    if (! *exists) {
        if (! create) {
            return Err(failure(
                ExitCode::Io,
                rstd::format("{}: error[io]: catalog directory does not exist", path.as_path())));
        }
        auto created = rstd::fs::create_dir_all(path.as_path());
        if (created.is_err()) return Err(io_failure(path.as_path(), created.unwrap_err()));
    }
    auto canonical = rstd::fs::canonicalize(path.as_path());
    if (canonical.is_err()) return Err(io_failure(path.as_path(), canonical.unwrap_err()));
    auto owned = rstd::move(canonical).unwrap_unchecked();
    if (! owned.as_path().starts_with(project.root.as_path())) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[unsafe-plugin-path]: catalog directory escapes "
                                        "plugin root",
                                        project.catalog_directory.as_str())));
    }
    auto metadata = rstd::fs::metadata(owned.as_path());
    if (metadata.is_err()) return Err(io_failure(owned.as_path(), metadata.unwrap_err()));
    if (! metadata->is_dir()) {
        return Err(
            failure(ExitCode::Plugin,
                    rstd::format("{}: error[plugin-manifest]: catalog path is not a directory",
                                 project.catalog_directory.as_str())));
    }
    return Ok(rstd::move(owned));
}

auto read_existing_catalog(const Project& project, ref<str> logical,
                           ref<rstd::path::Path> directory) -> ToolResult<Option<String>> {
    auto logical_path = rstd::path::PathBuf::from(logical);
    auto filename     = logical_path.as_path().file_name();
    if (filename.is_none()) {
        return Err(
            failure(ExitCode::Plugin,
                    rstd::format("{}: error[unsafe-plugin-path]: invalid catalog path", logical)));
    }
    auto path   = rstd::path::PathBuf::from(directory).join(ref<rstd::path::Path>(*filename));
    auto exists = rstd::fs::exists(path.as_path());
    if (exists.is_err()) return Err(io_failure(path.as_path(), exists.unwrap_err()));
    if (! *exists) return Ok(None());
    auto canonical = validate_owned_file(project, logical);
    if (canonical.is_err()) return Err(rstd::move(canonical).unwrap_err_unchecked());
    auto document = read_text_file(canonical->as_path());
    if (document.is_err()) return Err(rstd::move(document).unwrap_err_unchecked());
    return Ok(Some(rstd::move(document).unwrap_unchecked()));
}

auto update(const Project& project, const Vec<String>& locales,
            const luato::i18n::Extraction& extraction) -> ExitCode {
    if (locales.len() != usize(1)) {
        return emit(failure(ExitCode::Usage,
                            String::make("error: update requires exactly one --locale"_str)));
    }
    auto logical = catalog_logical_path(project, locales[usize()].as_str());
    if (logical.is_err()) return emit(rstd::move(logical).unwrap_err_unchecked());
    if (! project.declared_files.contains_key(logical->as_str())) {
        return emit(failure(ExitCode::Plugin,
                            rstd::format("{}: error[plugin-files]: catalog must be declared in "
                                         "files.txt",
                                         logical->as_str())));
    }

    auto directory = catalog_directory(project, true);
    if (directory.is_err()) return emit(rstd::move(directory).unwrap_err_unchecked());
    auto existing = read_existing_catalog(project, logical->as_str(), directory->as_path());
    if (existing.is_err()) return emit(rstd::move(existing).unwrap_err_unchecked());
    auto existing_ref = Option<ref<str>> {};
    if (existing->is_some()) existing_ref = Some(existing->as_ref().unwrap().as_str());
    auto rendered = luato::i18n::update_catalog(rstd::parse::SourceId(logical->clone()),
                                                locales[usize()].as_str(),
                                                existing_ref,
                                                extraction);
    if (rendered.is_err()) {
        emit_diagnostic(rendered.unwrap_err());
        return ExitCode::Catalog;
    }

    auto logical_path = rstd::path::PathBuf::from(logical->as_str());
    auto filename     = logical_path.as_path().file_name().unwrap();
    auto output_path  = directory->join(ref<rstd::path::Path>(filename));
    auto written =
        rstd::fs::write_atomic_if_changed(output_path.as_path(), rendered->as_str().as_bytes());
    if (written.is_err()) return emit(io_failure(output_path.as_path(), written.unwrap_err()));
    auto summary = rstd::format("{}: updated {}\n", project.id.as_str(), logical->as_str());
    write_text(stdout, summary.as_str());
    return ExitCode::Success;
}

auto requested_catalogs(const Project& project, const Vec<String>& locales,
                        ref<rstd::path::Path> directory) -> ToolResult<BTreeMap<String, String>> {
    auto catalogs = BTreeMap<String, String>::make();
    if (! locales.is_empty()) {
        for (const auto& locale : locales) {
            auto logical = catalog_logical_path(project, locale.as_str());
            if (logical.is_err()) return Err(rstd::move(logical).unwrap_err_unchecked());
            if (! project.declared_files.contains_key(logical->as_str())) {
                return Err(failure(ExitCode::Plugin,
                                   rstd::format("{}: error[plugin-files]: catalog is not declared "
                                                "in files.txt",
                                                logical->as_str())));
            }
            if (catalogs.insert(locale.clone(), rstd::move(logical).unwrap_unchecked()).is_some()) {
                return Err(
                    failure(ExitCode::Usage,
                            rstd::format("error: duplicate --locale '{}'", locale.as_str())));
            }
        }
        return Ok(rstd::move(catalogs));
    }

    auto entries = rstd::fs::read_dir(directory);
    if (entries.is_err()) return Err(io_failure(directory, entries.unwrap_err()));
    auto reader = rstd::move(entries).unwrap_unchecked();
    while (auto next = reader.next()) {
        auto entry_result = rstd::move(*next);
        if (entry_result.is_err()) return Err(io_failure(directory, entry_result.unwrap_err()));
        auto entry = rstd::move(entry_result).unwrap_unchecked();
        auto type  = entry.file_type();
        if (type.is_err()) return Err(io_failure(entry.path().as_path(), type.unwrap_err()));
        if (! type->is_file() && ! type->is_symlink()) continue;
        auto file_name = entry.file_name();
        auto name      = file_name.as_os_str().to_str();
        if (name.is_none() || ! name->ends_with(".json"_str)) continue;
        auto locale  = name->strip_suffix(".json"_str).unwrap();
        auto logical = catalog_logical_path(project, locale);
        if (logical.is_err()) return Err(rstd::move(logical).unwrap_err_unchecked());
        if (! project.declared_files.contains_key(logical->as_str())) {
            return Err(failure(ExitCode::Plugin,
                               rstd::format("{}: error[plugin-files]: catalog is not declared in "
                                            "files.txt",
                                            logical->as_str())));
        }
        catalogs.insert(String::make(locale), rstd::move(logical).unwrap_unchecked());
    }
    if (catalogs.is_empty()) {
        return Err(failure(ExitCode::Plugin,
                           rstd::format("{}: error[plugin-files]: no catalogs to check",
                                        project.catalog_directory.as_str())));
    }
    return Ok(rstd::move(catalogs));
}

auto check_catalog_policy(const luato::i18n::Catalog& catalog, ref<str> logical)
    -> ToolResult<empty> {
    for (auto item : catalog.messages.iter()) {
        auto [id, entry] = item;
        if (entry->translation.is_empty()) {
            return Err(failure(ExitCode::Catalog,
                               rstd::format("{}: error[catalog-incomplete]: message '{}' has no "
                                            "translation",
                                            logical,
                                            id->as_str())));
        }
        if (entry->needs_review) {
            return Err(failure(ExitCode::Catalog,
                               rstd::format("{}: error[catalog-review]: message '{}' needs review",
                                            logical,
                                            id->as_str())));
        }
    }
    if (! catalog.obsolete.is_empty()) {
        return Err(failure(
            ExitCode::Catalog,
            rstd::format("{}: error[catalog-obsolete]: obsolete messages remain", logical)));
    }
    return Ok(empty {});
}

auto check(const Project& project, const Vec<String>& locales,
           const luato::i18n::Extraction& extraction) -> ExitCode {
    auto directory = catalog_directory(project, false);
    if (directory.is_err()) return emit(rstd::move(directory).unwrap_err_unchecked());
    auto catalogs = requested_catalogs(project, locales, directory->as_path());
    if (catalogs.is_err()) return emit(rstd::move(catalogs).unwrap_err_unchecked());

    for (auto item : catalogs->iter()) {
        auto [locale, logical] = item;
        auto document = read_existing_catalog(project, logical->as_str(), directory->as_path());
        if (document.is_err()) return emit(rstd::move(document).unwrap_err_unchecked());
        if (document->is_none()) {
            return emit(failure(ExitCode::Catalog,
                                rstd::format("{}: error[catalog-missing]: catalog does not exist",
                                             logical->as_str())));
        }
        auto text         = document->as_ref().unwrap().as_str();
        auto synchronized = luato::i18n::check_catalog(
            rstd::parse::SourceId(logical->clone()), locale->as_str(), text, extraction);
        if (synchronized.is_err()) {
            emit_diagnostic(synchronized.unwrap_err());
            return ExitCode::Catalog;
        }
        auto parsed = luato::i18n::parse_catalog(
            rstd::parse::SourceId(logical->clone()), locale->as_str(), text);
        if (parsed.is_err()) {
            emit_diagnostic(parsed.unwrap_err());
            return ExitCode::Catalog;
        }
        auto policy = check_catalog_policy(*parsed, logical->as_str());
        if (policy.is_err()) return emit(rstd::move(policy).unwrap_err_unchecked());
    }

    auto summary =
        rstd::format("{}: {} catalog(s) synchronized\n", project.id.as_str(), catalogs->len());
    write_text(stdout, summary.as_str());
    return ExitCode::Success;
}

auto execute(const Request& request) -> ExitCode {
    if (request.mode == Mode::Update && request.locales.len() != usize(1)) {
        return emit(failure(ExitCode::Usage,
                            String::make("error: update requires exactly one --locale"_str)));
    }
    auto project = load_project(request.plugin.as_path());
    if (project.is_err()) return emit(rstd::move(project).unwrap_err_unchecked());
    auto sources = load_sources(*project);
    if (sources.is_err()) return emit(rstd::move(sources).unwrap_err_unchecked());
    auto extraction = extract_sources(*sources);
    if (extraction.is_err()) return extraction.unwrap_err().code;

    if (request.mode == Mode::Update) return update(*project, request.locales, *extraction);
    return check(*project, request.locales, *extraction);
}

} // namespace waywallen::i18n
