# gno is widely mislabelled as GPL-3.0. It is not.
#
# LICENSE.md in the gno tree is the "GNO Network General Public License",
# version 6, published by NewTendermint, LLC, which its own text describes as
# "a fork of the GNU Affero General Public License 3" and as free software.
# GitHub's license detector reports it as NOASSERTION / Other, so there is no
# SPDX identifier to use.
#
# The tm2/ subtree carries Apache-2.0 instead, so a binary built only from tm2
# is not covered by this.
{ lib }:

{
  gnoNgpl6 = lib.licenses.free // {
    shortName = "GNO-NGPL-6";
    fullName = "GNO Network General Public License, version 6";
    url = "https://github.com/gnolang/gno/blob/master/LICENSE.md";
    free = true;
    redistributable = true;
  };
}
