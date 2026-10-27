# Importar Cartão

App para macOS que faz o backup dos cartões de memória depois de uma gravação: cria a pasta da captação, copia vídeos, fotos RAW, áudios e documentos com o nome no padrão que você escolher, confere cada cópia byte a byte (SHA-256) e, se você quiser, faz uma segunda cópia em outro disco.

## Baixar

Baixe o `.dmg` mais recente em **Releases**, abra e arraste o app para Aplicativos. Na primeira abertura, o macOS pede para liberar o app em Ajustes do Sistema > Privacidade e Segurança > "Abrir Mesmo Assim" (ele não é assinado pela Apple). Detalhes em [LEIA-ME.txt](LEIA-ME.txt).

Requer macOS 14 ou mais novo (Apple Silicon ou Intel).

## O que ele faz

- Detecta o cartão sozinho (ou uma pasta escolhida à mão).
- Lista as captações com a mais recente no topo, com busca, e cria captações novas.
- Importa vídeos (MP4, MOV, MXF, BRAW), fotos RAW (CR2, CR3, ARW, NEF, RAF, RW2, ORF, DNG), áudios (MP3 e WAV) e, se marcado, documentos (PDF, Word, Pages, RTF, ODT).
- Numera na ordem de gravação e continua a numeração que já existe na pasta.
- Reconhece o que já foi importado (nesta ou em outra captação) e não copia de novo.
- Cópia de redundância opcional num segundo disco, com a mesma pasta e os mesmos nomes.
- Limpeza opcional do cartão, só do que bater byte a byte com a cópia.

## Configuração

Na primeira abertura (e depois em **Ajustes**, ⌘,):

- **Destino principal** e **redundância** (opcional).
- **Nome da pasta da captação**, ex.: `{AAAA}{MM}{DD} - {NOME}` → `20261027 - CASAMENTO ANA`.
- **Subpastas** de cada tipo e pastas extras vazias (ex.: `Fotos/Seleção`).
- **Nome dos arquivos** por tipo, ex.: `{PASTA} - {NNN}` → `20261027 - CASAMENTO ANA - 001.MP4`.

Etiquetas: `{PASTA}` nome da pasta da captação, `{NOME}` só o nome, `{AAAA}` `{AA}` `{MM}` `{DD}` data, `{N}` `{NN}` `{NNN}`… número com esse tanto de dígitos, `{ORIGINAL}` nome do arquivo no cartão.

## Compilar

Precisa das ferramentas de linha de comando do Xcode (`xcode-select --install`).

```bash
./build.sh      # gera build/Importar Cartão.app
./release.sh    # gera dist/Importar-Cartao-<versão>.dmg para compartilhar
```
