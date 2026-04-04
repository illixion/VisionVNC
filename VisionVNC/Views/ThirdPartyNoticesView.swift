import SwiftUI

struct ThirdPartyNoticesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("VisionVNC uses the following open source software:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                licenseSection(
                    name: "RoyalVNCKit",
                    copyright: "Copyright (c) 2025 Royal Apps",
                    license: mitLicenseText
                )

                licenseSection(
                    name: "moonlight-common-c",
                    copyright: "Copyright (C) 2007 Free Software Foundation, Inc.",
                    license: gpl3LicenseText
                )

                licenseSection(
                    name: "ENet",
                    copyright: "Copyright (c) 2002-2020 Lee Salzman",
                    license: mitLicenseText
                )

                licenseSection(
                    name: "Opus",
                    copyright: "Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon",
                    license: bsd3LicenseText
                )

                licenseSection(
                    name: "CryptoSwift",
                    copyright: "Copyright (C) 2014-3099 Marcin Krzyżanowski",
                    license: cryptoSwiftLicenseText
                )

                licenseSection(
                    name: "Cstb (stb)",
                    copyright: "Copyright (c) 2017 Sean Barrett",
                    license: mitLicenseText
                )
            }
            .padding()
        }
        .navigationTitle("Third-Party Notices")
    }

    private func licenseSection(name: String, copyright: String, license: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name)
                .font(.title3)
                .fontWeight(.semibold)

            Text(copyright)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(license)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
        }
    }

    private var mitLicenseText: String {
        """
        MIT License

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    }

    private var gpl3LicenseText: String {
        """
        GNU General Public License v3.0

        This program is free software: you can redistribute it and/or modify \
        it under the terms of the GNU General Public License as published by \
        the Free Software Foundation, either version 3 of the License, or \
        (at your option) any later version.

        This program is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
        GNU General Public License for more details.

        You should have received a copy of the GNU General Public License \
        along with this program. If not, see <https://www.gnu.org/licenses/>.
        """
    }

    private var bsd3LicenseText: String {
        """
        BSD 3-Clause License

        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        - Redistributions of source code must retain the above copyright notice, \
        this list of conditions and the following disclaimer.

        - Redistributions in binary form must reproduce the above copyright notice, \
        this list of conditions and the following disclaimer in the documentation \
        and/or other materials provided with the distribution.

        - Neither the name of Internet Society, IETF or IETF Trust, nor the names \
        of specific contributors, may be used to endorse or promote products derived \
        from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
        ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE \
        LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \
        CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \
        SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
        INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
        CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
        ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
        POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var cryptoSwiftLicenseText: String {
        """
        This software is provided 'as-is', without any express or implied warranty.

        In no event will the authors be held liable for any damages arising from \
        the use of this software.

        Permission is granted to anyone to use this software for any purpose, \
        including commercial applications, and to alter it and redistribute it \
        freely, subject to the following restrictions:

        - The origin of this software must not be misrepresented; you must not \
        claim that you wrote the original software. If you use this software in a \
        product, an acknowledgment in the product documentation is required.
        - Altered source versions must be plainly marked as such, and must not be \
        misrepresented as being the original software.
        - This notice may not be removed or altered from any source or binary \
        distribution.
        - Redistributions of any form whatsoever must retain the following \
        acknowledgment: 'This product includes software developed by the \
        "Marcin Krzyzanowski" (http://krzyzanowskim.com/).'
        """
    }
}
