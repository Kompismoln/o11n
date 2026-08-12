{
  o11nInputs,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    o11nInputs.nixvim.homeModules.nixvim
  ];

  home.packages = with pkgs; [
    nixfmt
    shellcheck
    shellharden
    shfmt
    bash-language-server
  ];

  programs.nixvim = {
    enable = true;
    vimAlias = true;

    diagnostic.settings = {
      underline = false;
      virtual_text = false;
      signs = true;
    };

    extraConfigLuaPost = ''
      local livepatch = vim.fn.stdpath('config') .. '/livepatch.lua'
      if vim.fn.filereadable(livepatch) == 1 then
        dofile(livepatch)
      end
    '';

    globals.mapleader = "\\";

    opts = {
      number = true;
      shiftwidth = 2;
      cursorline = true;
      tabstop = 2;
      expandtab = true;
      wildmenu = true;
      wildmode = "longest:full,full";
      foldmethod = "expr";
      foldexpr = "nvim_treesitter#foldexpr()";
      foldenable = false;
    };

    keymaps = [
      {
        key = "<C-c>";
        action = ":bd<cr>";
        options.desc = "Delete buffer";
      }
      {
        mode = "n";
        key = "<C-n>";
        action = "<C-w>w";
        options.desc = "Cycle to next window";
      }
      {
        mode = "n";
        key = "<C-p>";
        action = "<C-w>W";
        options.desc = "Cycle to previous window";
      }
      {
        key = "<C-x>";
        action = ":split | wincmd w <cr>";
        options.desc = "Split horizontally and move to the created window";
      }
      {
        key = "<C-v>";
        action = ":vsplit | wincmd w <cr>";
        options.desc = "Split vertically and move to the created window";
      }
      {
        key = "<leader>y";
        action = ''"+yy'';
        mode = [ "n" ];
      }
      {
        key = "<leader>y";
        action = ''"+y'';
        mode = [ "v" ];
      }
      {
        key = "<Enter>";
        mode = "x";
        action = "an";
        options = {
          remap = true;
          desc = "Incremental selection";
        };
      }
      {
        key = "<BS>";
        mode = "x";
        action = "in";
        options = {
          remap = true;
          desc = "Decremental selection";
        };
      }
      {
        key = "-";
        action = "<cmd>Oil<cr>";
        options.desc = "Open parent directory";
      }
      {
        key = "s";
        action = "<Plug>(leap-forward)";
        options.desc = "Open parent directory";
      }
      {
        key = "S";
        action = "<Plug>(leap-backward)";
        options.desc = "Open parent directory";
      }
      {
        key = "<leader>f";
        action.__raw = ''
          function()
            require("conform").format({ async = true, lsp_fallback = true })
          end
        '';
        options.desc = "Format buffer";
      }
      {
        key = "<leader>tf";
        action.__raw = ''
          function()
            vim.g.disable_autoformat = not vim.g.disable_autoformat
            print("Autoformat " .. (vim.g.disable_autoformat and "disabled" or "enabled"))
          end
        '';
        mode = "n";
        options.desc = "Toggle autoformat";
      }
      {
        key = "<leader>s";
        action.__raw = ''
            function()
          require("spectre").toggle()
          end
        '';
        mode = "n";
        options.desc = "Toggle Spectre";
      }
      {
        key = "<leader>r";
        action.__raw = ''
            function()
          require("spectre.actions").run_replace()
          end
        '';
        mode = "n";
        options.desc = "Spectre Replace";
      }
    ];

    plugins = {
      typst-vim.enable = true;
      web-devicons.enable = true;
      spectre.enable = true;
      leap.enable = true;
      sleuth.enable = true;
      nix.enable = true;
      colorizer.enable = true;
      fugitive.enable = true;
      gitignore.enable = false;

      direnv = {
        enable = true;
        autoLoad = true;
      };

      none-ls = {
        enable = true;
        sources = {
          diagnostics.statix.enable = true;
          code_actions.statix.enable = true;
          diagnostics.deadnix.enable = true;
        };
      };

      oil = {
        enable = true;
        settings = {
          skip_confirm_for_simple_edits = true;
          keymaps = {
            "<C-r>" = "actions.refresh";
            "y." = "actions.copy_entry_path";
            "<C-v>" = "actions.select_vsplit";
            "<C-x>" = "actions.select_split";
          };
        };
      };

      conform-nvim = {
        enable = true;
        autoLoad = true;
        settings = {
          formatters = {
            typstyle.command = lib.getExe pkgs.typstyle;
            squeeze_blanks.command = lib.getExe' pkgs.coreutils "cat";
            nixfmt.command = lib.getExe pkgs.nixfmt;
            ruff.command = lib.getExe pkgs.ruff;
          };
          formatters_by_ft = {
            markdown = [
              "squeeze_blanks"
              "trim_whitespace"
              "trim_newlines"
            ];
            typst = [
              "typstyle"
            ];
            nix = [
              "nixfmt"
            ];
            python = [
              "ruff_organize_imports"
              "ruff_format"
            ];
          };
          format_on_save =
            let
              timeout_ms = 1500;
              lsp_format = "fallback";
            in
            ''
              function(bufnr)
                if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
                  return
                end
                return { timeout_ms = ${toString timeout_ms}, lsp_format = "${lsp_format}" }
              end
            '';
        };
      };

      vim-matchup = {
        enable = true;
        autoLoad = true;
        treesitter.enable = true;
      };

      treesitter = {
        enable = true;
        highlight.enable = true;
        indent.enable = true;
        folding.enable = true;
      };

      telescope = {
        enable = true;
        keymaps = {
          "<leader>ff" = "find_files";
          "<leader>fg" = "live_grep";
          "<leader>fb" = "buffers";
          "<leader>fh" = "command_history";
        };
      };

      lsp = {
        enable = true;
        servers = {
          tinymist.enable = true;
          ts_ls.enable = true;
          svelte.enable = true;
          tailwindcss.enable = true;
          basedpyright.enable = true;
          ty.enable = false; # swap with basedpyright mid 2027
          ruff.enable = true;
          nixd.enable = true;
          eslint.enable = true;
          bashls.enable = true;
          tombi.enable = true;
          jsonls.enable = true;
        };
        keymaps = {
          lspBuf = {
            K = "hover";
            gd = "definition";
            gD = "declaration";
            gr = "references";
            gi = "implementation";
            gt = "type_definition";
          };
          diagnostic = {
            "<leader>d" = "open_float";
            "<leader>j" = "goto_next";
            "<leader>k" = "goto_prev";
          };
        };
      };

      cmp = {
        enable = true;
        autoEnableSources = true;
        settings = {
          completion = {
            keyword_length = 2;
          };
          sources = [
            { name = "nvim_lsp"; }
            { name = "luasnip"; }
            { name = "path"; }
            { name = "buffer"; }
          ];
          mapping = {
            "<C-Space>" = "cmp.mapping.complete()";
            "<S-CR>" = "cmp.mapping.confirm({ select = true })";
            "<S-Tab>" = "cmp.mapping(cmp.mapping.select_prev_item(), {'i', 's'})";
            "<Tab>" = "cmp.mapping(cmp.mapping.select_next_item(), {'i', 's'})";
          };
        };
      };
    };
  };
}
