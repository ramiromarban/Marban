# GUIZADO TV para iPhone

Versión nativa SwiftUI 1.0 para iPhone con iOS 16 o posterior.

## Descarga

[Descargar compilación validada: IPA y captura de Inicio](https://github.com/ramiromarban/Marban/actions/runs/41327060970/artifacts/13092280636)

El ZIP contiene `GUIZADO-TV-sin-firma.ipa`. **La IPA no está firmada:** necesita firma antes de instalarla en un iPhone. Puedes realizar ese paso desde Windows con [Sideloadly](https://sideloadly.io/), usando tu cuenta Apple directamente en esa aplicación. Una cuenta gratuita requiere renovar la firma cada siete días; no envíes contraseñas al chat.

## Validación

[Compilación verificada](https://github.com/ramiromarban/Marban/actions/runs/41327060970): Xcode 16.4, dispositivo arm64, comprobaciones de perfiles/progreso/canales, instalación y arranque en simulador. Inicio y sus carátulas se comprobaron en la captura. Reproducción en un iPhone físico, firma del usuario, PiP y AirPlay siguen pendientes.

## Código

Los archivos actuales están en `native/`. El ZIP del proyecto contiene los recursos; el workflow lo extrae, adapta el nombre de la carpeta de recursos a MediaAssets y aplica los archivos de native antes de compilar. No se incluyen certificados ni contraseñas.

Los artifacts de Actions caducan según la retención configurada; guarda la IPA descargada. Las fuentes externas de contenido pueden cambiar o dejar de estar disponibles.
