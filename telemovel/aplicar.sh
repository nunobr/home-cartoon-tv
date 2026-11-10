#!/usr/bin/env bash
# Transforma a app Jellyfin Android (em $1) na app "Home Cartoon".
set -euo pipefail
UP="$1"
AQUI="$(cd "$(dirname "$0")" && pwd)"
RES="$UP/app/src/main/res"

# Imagens
rm -f "$RES/drawable/ic_launcher_foreground.xml" "$RES/drawable/ic_splash.xml" "$RES/drawable/app_logo.xml"
cp -r "$AQUI/res/." "$RES/"

# Nome
sed -i 's#<string name="app_name" translatable="false">Jellyfin</string>#<string name="app_name" translatable="false">Home Cartoon</string>#' "$RES/values/strings_donottranslate.xml"
sed -i 's#<string name="app_name_short" translatable="false">Jellyfin</string>#<string name="app_name_short" translatable="false">Home Cartoon</string>#' "$RES/values/strings_donottranslate.xml"
grep -q '>Home Cartoon</string>' "$RES/values/strings_donottranslate.xml"

# Cor de fundo do ícone
sed -i 's#<color name="ic_launcher_background">[^<]*</color>#<color name="ic_launcher_background">\#1B2A49</color>#' "$RES/values/colors.xml"

# Identificador próprio (instala-se ao lado do Jellyfin) e nome do ficheiro
sed -i 's#^\(\s*\)minSdk = #\1applicationId = "pt.homecartoon.mobile"\n\1minSdk = #' "$UP/app/build.gradle.kts"
grep -q 'applicationId = "pt.homecartoon.mobile"' "$UP/app/build.gradle.kts"
sed -i 's#jellyfin-android-v#home-cartoon-telemovel-v#' "$UP/app/build.gradle.kts"
echo "Home Cartoon aplicado."
