# Acervo

**Português** · [English](#english) · [Español](#español)

App para macOS que faz o backup dos cartões de memória depois de uma gravação: cria a pasta da captação, copia vídeos, fotos, áudios e o que mais você quiser para as subpastas certas, com o nome no padrão que você escolher, confere cada cópia com xxHash64, faz cópias de redundância em outros discos e gera relatório em PDF e registro ASC MHL.

## Baixar

Baixe o `.dmg` mais recente em **[Releases](../../releases/latest)**, abra e arraste o Acervo para Aplicativos.

Na primeira abertura, o macOS avisa que não pode verificar o desenvolvedor (o app não é assinado pela Apple). Para liberar: abra o app uma vez, vá em **Ajustes do Sistema > Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim**.

Requer macOS 14 ou mais novo, em Mac com Apple Silicon ou Intel. Em português, inglês e espanhol, seguindo o idioma do sistema.

### Windows (beta)

Também há uma versão para **Windows 10 e 11 (64 bits)**, com as mesmas funções: baixe o `Acervo-…-Windows-beta.zip` em Releases, descompacte e abra o `Acervo.exe` (não precisa instalar). Na primeira vez, o Windows pode avisar que protegeu o computador: clique em **Mais informações > Executar assim mesmo**. É uma versão de testes, ainda não testada num PC com Windows: experimente primeiro com um cartão que já tenha backup e conte em **Issues** se algo der errado.

## O que ele faz

- Detecta os cartões sozinho (ou usa uma pasta escolhida à mão) e copia **vários cartões ao mesmo tempo**, um por leitor, para a mesma captação, com a numeração na ordem de gravação de todas as câmeras ou separando cada cartão numa subpasta.
- Lista as captações com a mais recente no topo, com busca, e cria captações novas.
- Cada subpasta da captação recebe os tipos de arquivo que você definir: vídeos (MP4, MOV, MXF, BRAW), fotos RAW (CR2, CR3, ARW, NEF, RAF, RW2, ORF, DNG), JPG/HEIC, áudios (MP3, WAV), documentos (PDF, Word…), PSD/AI ou qualquer extensão.
- Renomeia os arquivos com o nome da pasta da captação ou um padrão seu, numerando na ordem de gravação e continuando a numeração que já existe. Ou mantém os nomes originais.
- Reconhece o que já foi importado (nesta ou em outra captação) e não copia de novo.
- Copia ao mesmo tempo para um ou mais discos de redundância, com a mesma pasta e os mesmos nomes (uma pasta do Google Drive ou do Dropbox também serve), e avisa quando o cartão está **seguro para formatar** (tudo conferido em 2 discos).
- Confere cada cópia relendo do disco com **xxHash64** e gera, se você quiser, um **relatório em PDF** e o registro **ASC MHL** (padrão do mercado, compatível com Silverstack, ShotPut e OffShoot).
- Limpa o cartão no fim, se você pedir, só depois de reler e comparar cada arquivo com a cópia.

## Configuração

Na primeira abertura (e depois em **Ajustes**, ⌘,):

| | |
|---|---|
| **Disco principal** | onde o backup é feito |
| **Discos de redundância** | cópias idênticas em outros discos (opcional) |
| **Pasta de cada captação** | ex.: `{AAAA}{MM}{DD} - {NOME}` → `20261027 - CASAMENTO ANA`, e as subpastas com o que cada uma recebe |
| **Nome dos arquivos** | ex.: `{PASTA} - {NNN}` → `20261027 - CASAMENTO ANA - 001.MP4` |
| **Relatórios** | PDF de cada importação (junto do backup ou numa pasta escolhida) e registro ASC MHL |
| **Discos ignorados** | discos de trabalho que nunca devem aparecer como cartão |

Etiquetas: `{PASTA}` nome da pasta da captação · `{NOME}` só o nome · `{AAAA}` `{AA}` `{MM}` `{DD}` data · `{N}` `{NN}` `{NNN}`… número com esse tanto de dígitos · `{ORIGINAL}` nome do arquivo no cartão. Também valem em inglês (`{FOLDER}`, `{NAME}`, `{YYYY}`) e espanhol (`{CARPETA}`, `{NOMBRE}`).

## Compilar

**Mac** (Swift, pasta `Sources`): precisa das ferramentas de linha de comando do Xcode (`xcode-select --install`).

```bash
./build.sh      # gera build/Acervo.app
./release.sh    # gera dist/Acervo-<versão>.dmg para compartilhar
```

**Windows** (C# com Avalonia, pasta `windows`): precisa do [.NET 10](https://dot.net). Dá para gerar no Mac ou no Windows.

```bash
windows/build-windows.sh   # gera dist/Acervo-<versão>-Windows-beta.zip
```

## Licença

[MIT](LICENSE): pode usar, modificar e redistribuir à vontade, mantendo o aviso de autoria.

---

## English

A macOS app that backs up memory cards after a shoot: it creates the shoot folder, copies videos, photos, audio and anything else you want into the right subfolders, names files with your own pattern, copies several cards at once, verifies every copy with xxHash64, makes redundant copies on other drives and writes a PDF report and an ASC MHL record.

**Download** the latest `.dmg` from **[Releases](../../releases/latest)** and drag Acervo to Applications. The first time, macOS can't verify the developer (the app isn't signed by Apple): open it once, then go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.

On first launch you choose the main drive, optional redundancy drives, the folder and subfolder structure (and which file types each subfolder gets) and how files are named. Tags: `{FOLDER}` `{NAME}` `{YYYY}` `{YY}` `{MM}` `{DD}` `{NNN}` `{ORIGINAL}`.

Requires macOS 14 or later (Apple Silicon or Intel). A **Windows 10/11 beta** (`Acervo-…-Windows-beta.zip`, just unzip and run `Acervo.exe`) is also available; it hasn't been tested on a real Windows PC yet. Available in English, Portuguese and Spanish, following the system language.

## Español

App para macOS que hace la copia de seguridad de las tarjetas de memoria después de un rodaje: crea la carpeta del rodaje, copia videos, fotos, audios y lo que quieras a las subcarpetas correctas, nombra los archivos con tu propio patrón, copia varias tarjetas a la vez, verifica cada copia con xxHash64, hace copias de redundancia en otros discos y genera un informe PDF y un registro ASC MHL.

**Descarga** el `.dmg` más reciente en **[Releases](../../releases/latest)** y arrastra Acervo a Aplicaciones. La primera vez, macOS no puede verificar al desarrollador (la app no está firmada por Apple): ábrela una vez, ve a **Ajustes del Sistema > Privacidad y Seguridad**, baja hasta el final y haz clic en **Abrir igualmente**.

En el primer uso eliges el disco principal, los discos de redundancia (opcional), la estructura de carpetas y subcarpetas (y qué tipos de archivo recibe cada una) y cómo se nombran los archivos. Etiquetas: `{CARPETA}` `{NOMBRE}` `{AAAA}` `{AA}` `{MM}` `{DD}` `{NNN}` `{ORIGINAL}`.

Requiere macOS 14 o posterior (Apple Silicon o Intel). También hay una **versión beta para Windows 10/11** (`Acervo-…-Windows-beta.zip`: descomprime y abre `Acervo.exe`), aún no probada en un PC con Windows. Disponible en español, portugués e inglés, según el idioma del sistema.
