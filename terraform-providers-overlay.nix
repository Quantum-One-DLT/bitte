inputs:
let
  inherit (inputs) nixpkgs;
  inherit (nixpkgs) lib;
in final: prev: {

  inherit (prev) terraform_0_13 terraform_0_14;

  terraform-provider-names =
    [ "acme" "aws" "consul" "local" "nomad" "null" "sops" "tls" "vault" ];

  terraform-provider-versions = lib.listToAttrs (map (name:
    let
      provider = final.terraform-providers.${name};
      provider-source-address =
        provider.provider-source-address or "registry.terraform.io/nixpkgs/${name}";
      parts = lib.splitString "/" provider-source-address;
      source = lib.concatStringsSep "/" (lib.tail parts);
    in lib.nameValuePair name {
      inherit source;
      version = "= ${provider.version}";
    }) final.terraform-provider-names);

  terraform-providers = prev.terraform-providers // (let
    inherit (prev) buildGoModule;
    buildWithGoModule = data:
      buildGoModule {
        pname = data.repo;
        version = data.version;
        subPackages = [ "." ];
        src = prev.fetchFromGitHub { inherit (data) owner repo rev sha256; };
        vendorSha256 = data.vendorSha256 or null;

        # Terraform allow checking the provider versions, but this breaks
        # if the versions are not provided via file paths.
        postBuild = "mv $NIX_BUILD_TOP/go/bin/${data.repo}{,_v${data.version}}";
        passthru = data;
      };
  in {
    acme = buildWithGoModule {
      provider-source-address = "registry.terraform.io/getstackhead/acme";
      version = "1.5.0-patched2";
      vendorSha256 = "0qapar40bdbyf7igf7fg5riqdjb2lgzi4z0l19hj7q1xmx4m8mgx";
      owner = "getstackhead";
      repo = "terraform-provider-acme";
      rev = "v1.5.0-patched2";
      sha256 = "1h6yk0wrn1dxsy9dsh0dwkpkbs8w9qjqqc6gl9nkrqbcd558jxfb";
    };
    consul = buildWithGoModule {
      provider-source-address = "registry.terraform.io/hashicorp/consul";
      version = "2.11.0";
      vendorSha256 = null;
      owner = "hashicorp";
      repo = "terraform-provider-consul";
      rev = "v2.11.0";
      sha256 = "007v7blzsfh0gd3i54w8jl2czbxidwk3rl2wgdncq423xh9pkx1d";
    };
    vault = buildWithGoModule {
      provider-source-address = "registry.terraform.io/hashicorp/vault";
      version = "2.18.0";
      vendorSha256 = null;
      owner = "hashicorp";
      repo = "terraform-provider-vault";
      rev = "v2.18.0";
      sha256 = "0lmgh9w9n0qvg9kf4av1yql2dh10r0jjxy5x3vckcpfc45lgsy40";
    };
    sops = buildWithGoModule {
      version = "0.6.3";
      vendorSha256 = "sha256-kBQVgxeGTu0tLgbjoCMdswwMvfZI3tEXNHa8buYJXME=";
      owner = "carlpett";
      repo = "terraform-provider-sops";
      rev = "v0.6.3";
      sha256 = "sha256-yfHO/vGk7M5CbA7VkrxLVldAMexhuk0wTEe8+5g8ZrU=";
    };
  });

  terraform-with-plugins = final.terraform_0_13.withPlugins
    (plugins: lib.attrVals final.terraform-provider-names plugins);
}
