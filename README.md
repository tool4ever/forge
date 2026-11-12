# Fork guidance

This is my personal (mostly) "AI slop free" adaption.

2026 was a wild year for the Forge project as LLM contributions really started coming in at full speed.
These certainly resulted in a lot of valueable features - e.g. online drafting, iOS support and stickers.

But a less capable coding agent in the hands of an overeager person can lead to a slowly enfolding disaster:
duct tape logic, technical debt and regressions that often take experience to spot instead of getting blinded from false security via countless badly written tests. 💣
In the end you'd be stuck with a very bloated code base that basically requires using an agent to work with...

Pushing back against low effort, sometimes even redundant PR and cleaning up after them takes time that could be better spent elsewhere.
Therefore this branch aims to be more conservative in keeping vibecode: implementations deemed too messy to recover from will simply be reverted here, either full PR / commit / parts as necessary.

Additionally semi-official/rare abilities that unnecessarily put a heavy strain on the engine may get reworked into slightly more hardcoded variants - e.g. just because the card *Topsy Turvy* is supported not all games should have to suffer extra checks for it.

While parity with upstream will be attempted to remain high, possibly and depending on the speed of slop merges especially some GUI features could become excluded from this branch in the future.
That means this approach should be most useful for other downstream consumers who just need a reliable engine to build around - or if you simply want less risk of being a guinea pig for LLM hallucinations.

There will be no releases for now, though everyone is welcome to give feedback if they have a problem specific to this build.

<details>
<summary>Overview of important fork amendments</summary>

| Slop suspect | Rationale | Priority |
| - | - | - |
| e6f4f67a | one of the first more complex parts was merged completely unreviewed. it had no regard for existing systems or other PR in progress, the first iteration broke netplay support and quickly caused memory problems for mobile users | B |
| dc72214 | extreme test bloat + hides bugs | A |
| 9c77436 | adding overhead for artificial problems coming from wrong method usage | A |
| 1406f4e | incomplete and badly written fix at absolutely the wrong layer | A |
| 082e9ff | implements an unnecessary cache for tokens. at this point it seems like either the own code just doesn't get checked anymore or the LLM dumping has become too tempting to slow down | A |
| anything relying on try-catch usage everywhere | author doesn't understand why his code fails | B |
| Flat MC | some good ideas but also very unhealthy amounts of vibecode with little manual testing, which then lead to additional bandaids slapped on top - e.g. 8360afa<br>but the nail in the coffin is it not even fully respecting the preference - e.g. `discardTargetAI`<br>-> this leads to a mix that actually worsens AI behaviour while also making it harder to debug user reports<br><br>some "highlights":<br>- fragile tests due to relying on reflection (without a good reason)<br>- rule-breaking script refactors | C |

Due to the many infected files from AI-related changes these will require a more careful "brain surgery" - probably only after that slop train hopefully slows down a bit. The current strategy is to keep a secondary `forge-ai-stable` module structure which can be swapped in-place (only irrelevant test classes with compile errors). This avoids some extra merge conflicts and bonus fixes no longer fitting into its parent have already been built into it.

</details>

---

# ⚔️  Forge: The Magic: The Gathering Rules Engine

Join the **Forge community** on [Discord](https://discord.gg/HcPJNyD66a)!

[![Test build](https://github.com/Card-Forge/forge/actions/workflows/test-build.yaml/badge.svg)](https://github.com/Card-Forge/forge/actions/workflows/test-build.yaml)

---

## ✨ Introduction
**Forge** is a dynamic and open-source **Rules Engine** tailored for **Magic: The Gathering** enthusiasts. Developed by a community of passionate programmers, Forge allows players to explore the rich universe of MTG through a flexible, engaging platform. 

**Note:** Forge operates independently and is not affiliated with Wizards of the Coast.

---

## 🌟 Key Features
- **🌐 Cross-Platform Support:** Play on **Windows, Mac, Linux,** and **Android**.
- **🔧 Extensible Architecture:** Built in **Java**, Forge encourages developers to contribute by adding features and cards.
- **🎮 Versatile Gameplay:** Dive into single-player modes or challenge opponents online!

---

## 🛠️ Installation Steps

### 📥 Desktop
1. **Latest Releases:** Download the latest version [here](https://github.com/Card-Forge/forge/releases/latest).
2. **Snapshot Build:** For the latest development version, grab the `forge-gui-desktop` tarball from our [Snapshot Build](https://github.com/Card-Forge/forge/releases/tag/daily-snapshots).
   - **Tip:** Extract to a new folder to prevent version conflicts.
3. **User Data Management:** Previous players’ data is preserved during upgrades.
4. **Java Requirement:** Ensure you have **Java 17 or later** installed.

### 📱 Android
- _(Note: **Android 11** is the minimum requirement with at least **6GB RAM** to run smoothly. You need to enable **"Install unknown apps"** for Forge to initialize and update itself)_
- Download the **APK** from the [Snapshot Build](https://github.com/Card-Forge/forge/releases/tag/daily-snapshots). On the first launch, Forge will automatically download all necessary assets.

### 📱 iOS (early stage)
- Build the **IPA** according to Wiki
- No jailbreak needed, only developer mode and iOS 16-27
- Connect your device to a PC to self-sign and upload the app file, multiple tools exist e.g. [Sideloadly](https://sideloadly.io)

---

## 🎮 Modes of Play
Forge offers various exciting gameplay options:

### 🌍 Adventure Mode
Embark on a thrilling single-player journey where you can:
- Explore an overworld map.
- Challenge diverse AI opponents.
- Collect cards and items to boost your abilities.

<img width="1282" height="752" alt="Shandalar World" src="https://github.com/user-attachments/assets/9af31471-d688-442f-9418-9807d8635b72" />

### 🔍 Quest Mode
Engage in focused gameplay without the overworld exploration—perfect for quick sessions!

<img width="1282" height="752" alt="Quest Duels" src="https://github.com/user-attachments/assets/b9613b1c-e8c3-4320-8044-6922c519aad4" />

### 🤖 AI Formats
Test your skills against AI in multiple formats:
- **Sealed**
- **Draft**
- **Commander**
- **Cube**

For comprehensive gameplay instructions, visit our [User Guide](https://github.com/Card-Forge/forge/wiki/User-Guide).

<img width="1282" height="752" alt="Sealed" src="https://github.com/user-attachments/assets/ae603dbd-4421-4753-a333-87cb0a28d772" />

---

## 💬 Support & Community
Need help? Join our vibrant Discord community! 
- 📜 Read the **#rules** and explore the **FAQ**.
- ❓ Ask your questions in the **#help** channel for assistance.

---

## 🤝 Contributing to Forge
We love community contributions! Interested in helping? Check out our [Contributing Guidelines](CONTRIBUTING.md) for details on how to get started.

---

## ℹ️ About Forge
Forge aims to deliver an immersive and customizable Magic: The Gathering experience for fans around the world. 

### 📊 Repository Statistics

| Metric         | Count                                                       |
|----------------|-------------------------------------------------------------|
| **⭐ Stars:**   | [![GitHub stars](https://img.shields.io/github/stars/Card-Forge/forge?style=flat-square)](https://github.com/Card-Forge/forge/stargazers) |
| **🍴 Forks:**   | [![GitHub forks](https://img.shields.io/github/forks/Card-Forge/forge?style=flat-square)](https://github.com/Card-Forge/forge/network) |
| **👥 Contributors:** | [![GitHub contributors](https://img.shields.io/github/contributors/Card-Forge/forge?style=flat-square)](https://github.com/Card-Forge/forge/graphs/contributors) |

---

**📄 License:** [GPL-3.0](LICENSE)
<div align="center" style="display: flex; align-items: center; justify-content: center;">
    <div style="margin-left: auto;">
        <a href="#top">
            <img src="https://img.shields.io/badge/Back%20to%20Top-000000?style=for-the-badge&logo=github&logoColor=white" alt="Back to Top">
        </a>
    </div>
</div>
