{
  app,
  lib,
  org,
  pkgs,
  ...
}:
let
  defaultLanguage = lib.head app.languages;

  suffixOf = language: lib.optionalString (language != defaultLanguage) ".${language}";

  strings = {
    sv = {
      services = "Tjänster";
      posts = "Inlägg";
      all_posts = "Alla inlägg";
      menu = "Meny";
      theme = "Ljust eller mörkt läge";
      login = "Logga in";
      logout = "Logga ut";
      account = "Konto";
      signed_in_as = "Inloggad som";
      contact = "Kontakt";
      feed = "Flöde";
      not_found = "Sidan finns inte.";
      home = "Till startsidan";
      language = "Svenska";
      form_email = "E-postadress";
      form_text = "Meddelande";
      form_invalid = "Adressen ser inte ut att stämma. Försök igen.";
      form_failed = "Det gick inte att skicka. Skriv direkt till";
      invite_title = "Vill du ha ett konto?";
      invite_text = "Konton ges på inbjudan. Lämna din adress, och gärna några ord om dig, så hör vi av oss.";
      invite_send = "Be om en inbjudan";
      invite_sent = "Tack! Vi hör av oss.";
      inquiry_send = "Skicka";
      inquiry_sent = "Tack! Meddelandet är skickat, och du får svar till din adress.";
      status = "Driftstatus";
      cv_about = "Om mig";
      cv_profile = "Profil";
      cv_skills = "Teknisk kompetens";
      cv_experience = "Erfarenhet";
      cv_education = "Utbildning";
      cv_languages = "Språk";
      cv_present = "nu";
      cv_download = "Ladda ner CV (PDF)";
      cv_available = "Tillgänglighet, andel av heltid";
      month_01 = "jan";
      month_02 = "feb";
      month_03 = "mar";
      month_04 = "apr";
      month_05 = "maj";
      month_06 = "jun";
      month_07 = "jul";
      month_08 = "aug";
      month_09 = "sep";
      month_10 = "okt";
      month_11 = "nov";
      month_12 = "dec";
    };
    en = {
      services = "Services";
      posts = "Posts";
      all_posts = "All posts";
      menu = "Menu";
      theme = "Light or dark mode";
      login = "Log in";
      logout = "Log out";
      account = "Account";
      signed_in_as = "Signed in as";
      contact = "Contact";
      feed = "Feed";
      not_found = "There is no such page.";
      home = "Back home";
      language = "English";
      form_email = "Email address";
      form_text = "Message";
      form_invalid = "That address doesn't look right. Try again.";
      form_failed = "It couldn't be sent. Write directly to";
      invite_title = "Want an account?";
      invite_text = "Accounts are by invitation. Leave your address, and a few words about you if you like, and we'll be in touch.";
      invite_send = "Request an invite";
      invite_sent = "Thanks! We'll be in touch.";
      inquiry_send = "Send";
      inquiry_sent = "Thanks! Your message is sent, and you'll get an answer at your address.";
      status = "Status";
      cv_about = "About me";
      cv_profile = "Profile";
      cv_skills = "Technical skills";
      cv_experience = "Experience";
      cv_education = "Education";
      cv_languages = "Languages";
      cv_present = "present";
      cv_download = "Download CV (PDF)";
      cv_available = "Availability, share of full time";
      month_01 = "Jan";
      month_02 = "Feb";
      month_03 = "Mar";
      month_04 = "Apr";
      month_05 = "May";
      month_06 = "Jun";
      month_07 = "Jul";
      month_08 = "Aug";
      month_09 = "Sep";
      month_10 = "Oct";
      month_11 = "Nov";
      month_12 = "Dec";
    };
  };

  issuer = lib.mapNullable (
    client: "${org.app.${client.keycloak}.url}/realms/${client.realm}"
  ) app.client;

  data = {
    inherit (org) name contact;
    logo =
      if app.logo == null then null else "/logo.${lib.last (lib.splitString "." (baseNameOf app.logo))}";
    inherit (app)
      accent
      accentHeader
      skyHeader
      logoHeight
      ;
    services = map (name: {
      inherit name;
      inherit (org.app.${name}) url kind;
    }) app.services;
    invites = app.invites != null;
    inherit (app) inquiries;
    status = lib.findFirst (url: url != null) null (
      lib.mapAttrsToList (
        _: other: if other.kind == "status" && other.portal == app.name then other.url else null
      ) org.app
    );
    auth = lib.mapNullable (client: {
      inherit issuer;
      inherit (client.representation) clientId;
      account = "${issuer}/account";
    }) app.client;
  };

  config = (pkgs.formats.toml { }).generate "config.toml" {
    base_url = app.url;
    title = org.name;
    default_language = defaultLanguage;
    compile_sass = false;
    build_search_index = false;
    markdown.insert_anchor_links = "heading";
    generate_feeds = true;
    feed_filenames = [ "atom.xml" ];
    translations = strings.${defaultLanguage};
    extra = lib.filterAttrsRecursive (_: value: value != null) data;
    languages = lib.genAttrs (lib.tail app.languages) (language: {
      title = org.name;
      generate_feeds = true;
      feed_filenames = [ "atom.xml" ];
      translations = strings.${language};
    });
  };

  fonts = pkgs.runCommand "${app.name}-fonts" { } ''
    mkdir $out
    ln -s ${pkgs.inter}/share/fonts/truetype/Inter.ttc $out/
  '';

  cv = pkgs.writeShellScript "${app.name}-cv" ''
    set -euo pipefail
    command=$1
    content=$(realpath "$2")
    out=$3
    pids=()
    # Fact: a job in the background of a script ignores SIGINT, so `serve` stops this with SIGTERM, which it passes on.
    trap 'kill "''${pids[@]}" 2>/dev/null; exit' TERM
    ${lib.concatMapStrings (language: ''
      while IFS= read -r -d "" cv; do
        rel=''${cv#"$content"/}
        dir=$(dirname "$rel")
        mkdir -p "$out/$dir"
        url=${app.url}/${lib.optionalString (language != defaultLanguage) "${language}/"}
        [[ $dir == . ]] || url+=$dir/
        ${pkgs.typst}/bin/typst "$command" --root / --ignore-system-fonts --font-path ${fonts} \
          --input data="$cv" --input strings=${stringsJson} --input lang=${language} \
          --input accent=${lib.escapeShellArg app.accent} --input url="$url" --input icons=${./static/icons} \
          ${./cv.typ} "$out/''${rel%.toml}.pdf" &
        pids+=($!)
      done < <(find -L "$content" -name cv${suffixOf language}.toml -print0)
    '') app.languages}
    for pid in "''${pids[@]}"; do wait "$pid"; done
  '';

  # Policy: a chip in a section's text names a skill its CV has.
  chips = pkgs.writeShellScript "${app.name}-chips" ''
    set -euo pipefail
    status=0
    while IFS= read -r -d "" page; do
      for id in $(grep -o 'href="#skill-[^"]*"' "$page" | cut -d'#' -f2 | tr -d '"' | sort -u); do
        if ! grep -qF "id=\"$id\"" "$page"; then
          echo "''${page#"$1"/}: a chip names ''${id#skill-}, a skill the section's CV in its language doesn't have" >&2
          status=1
        fi
      done
    done < <(find "$1" -name index.html -print0)
    exit $status
  '';

  # Policy: an icon a component names is one the site has.
  icons = pkgs.writeShellScript "${app.name}-icons" ''
    set -euo pipefail
    status=0
    while IFS= read -r -d "" page; do
      for icon in $(grep -o 'url(/icons/[^)]*\.svg)' "$page" | sed 's|^url(/icons/||; s|\.svg)$||' | sort -u); do
        if [[ ! -f $1/icons/$icon.svg ]]; then
          echo "''${page#"$1"/}: a component names the icon $icon, which the site doesn't have" >&2
          status=1
        fi
      done
    done < <(find "$1" -name index.html -print0)
    exit $status
  '';

  stringsJson = pkgs.writeText "${app.name}-strings.json" (builtins.toJSON strings);

  # Accommodating for Zola, which makes its HTTP client as it starts, and fails without CA certificates.
  certificates = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  source = pkgs.runCommand "${app.name}-site-source" { } ''
    mkdir $out
    cp -r ${./templates} $out/templates
    cp -r ${./static} $out/static
    chmod -R u+w $out
    ${lib.optionalString (app.logo != null) "cp ${app.logo} $out/static${data.logo}"}
    cp ${config} $out/config.toml
  '';
in
{
  site =
    pkgs.runCommand "${app.name}-site"
      {
        nativeBuildInputs = [ pkgs.zola ];
        SSL_CERT_FILE = certificates;
      }
      ''
        cp -r ${source} src
        chmod -R u+w src
        cd src
        cp -r ${app.content} content
        zola build --output-dir $out
        ${chips} $out
        ${icons} $out
        ${cv} compile content $out
      '';

  serve = pkgs.writeShellScript "${app.name}-serve" ''
    set -euo pipefail
    content=$(realpath "$1")
    shift
    dir=$(mktemp -d)
    trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$dir"' EXIT
    cp -r ${source}/. "$dir"
    chmod -R u+w "$dir"
    ln -s "$content" "$dir/content"
    ${cv} watch "$content" "$dir/static" &
    [[ -r ''${SSL_CERT_FILE:-} ]] || export SSL_CERT_FILE=${certificates}
    ${pkgs.zola}/bin/zola --root "$dir" serve "$@"
  '';
}
