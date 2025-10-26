# CC:Tweaked-Draconic Manager

## Description

CC:Tweaked-Draconic Manager is a comprehensive control and monitoring program designed for ComputerCraft: Tweaked to manage Draconic Evolution reactors and energy cores. This system ensures the safe and efficient operation of your reactors and energy storage, leveraging wireless modem communication for a seamless and flexible setup.

## Project Status: Proof of Concept

This project was originally created as a **proof of concept** and is no longer under active development.  
Due to limited time, I’m unable to continue maintaining or expanding it.  

If anyone is interested in taking over development, **you are welcome to do so** — feel free to fork, modify, and build upon the existing work.  
Credit is appreciated but not required. My goal was simply to demonstrate the core idea and provide a foundation for others to expand on.

## Features

- **Advanced Computer Touchscreen Interface**: Dynamically adjusting interface for easy interaction with your reactor and energy core.
- **Automated Regulation**: Maintains the input gate for a targeted field strength of 50%, adjustable as needed.
- **Failsafe Mechanisms**:
  - Immediate shutdown if field strength drops below 20% (adjustable).
  - Automatic activation upon successful charge.
  - Immediate shutdown if temperature exceeds 8000°C (adjustable).
  - Automatic activation when temperature cools down to 3000°C (adjustable).
- **Interactive Controls**: Easily tweak your output flux gate with touchscreen buttons in increments of +/-100k, 10k, and 1k.
- **Comprehensive Monitoring**: Visual indicators, graphs, gauges, and colored status indicators for real-time reactor and energy core status.
- **Alert System**: Notifies players when the reactor is low on fuel.
- **Statistics Logging**: Records all aspects of the reactor and energy core performance for detailed analysis.
- **Plug-and-Play Setup**: Automatically detects peripherals and configures them for use.
- **Dynamic Monitor Adjustment**: Supports two sets of monitors that automatically adjust to the player's desired size.

## Requirements

- **Minecraft Mods**: Draconic Evolution, ComputerCraft: Tweaked
- **Hardware**:
  - Draconic Evolution reactor fully set up with fuel
  - Draconic Evolution energy core fully set up
  - Advanced computer with wireless modem
  - Monitors (3x3 or larger setup) with wireless modems
  - Wireless modems for each reactor and energy core component

## Installation

1. **Setup your hardware**:
   - Ensure your reactor and energy core are fully assembled.
   - Attach wireless modems to the reactor components and energy core.
   - Connect the advanced computer and monitors with wireless modems.

2. **Download the install script**:
   - Run the following command to download the installation script from GitHub:
     ```shell
     wget https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/install.lua install.lua
     ```

3. **Run the install script**:
   - Execute the install script to download and configure all necessary files:
     ```shell
     install
     ```

4. **Configuration**:
   - Edit the `config.lua` file to adjust settings such as target field strength, max temperature, and other parameters.
   - Save the changes and restart the program.

## Offline Installation Instructions

If the server has the HTTP API disabled, you can install this software manually using a floppy disk.

### Steps for Offline Installation

1. **Prepare the Floppy Disk:**
   - On a ComputerCraft computer with access to the required files, place all the necessary scripts into the `disk` directory of a floppy disk:
     - `config.lua`
     - `main_control.lua`
     - `energy_core_utils.lua`
     - `reac_utils.lua`
     - `monitor_utils.lua`
     - `stat_utils.lua`

   - You can copy files to the disk with the following commands:
     ```lua
     fs.copy("path/to/file.lua", "disk/file.lua")
     ```

2. **Insert the Disk into the Target Computer:**
   - Place the floppy disk into the ComputerCraft computer where the software needs to be installed.

3. **Create the Offline Installer Script:**
   - On the target computer, create a new file named `offline_install.lua` and paste the following script into it:
     ```lua
     shell.run("edit offline_install.lua")
     ```
   - Copy and paste the script from the `offline_install.lua` section in the project repository.

4. **Run the Installer:**
   - Execute the installer with the following command:
     ```lua
     offline_install
     ```

5. **Reboot the Computer:**
   - After the installation is complete, reboot the computer. The software will start automatically.

### Notes
- Ensure that all required files are present on the floppy disk before running the installer.
- If the startup script (`startup.lua`) is not created automatically, you can manually create it with the following command:
  ```lua
  shell.run("edit startup.lua")
  ```

## Usage

- **Start the program**:
  - On your advanced computer, type `startup` and press enter.
  - The system will initialize and display the reactor and energy core status on the monitors.

- **Interactive Controls**:
  - Use the touchscreen interface to adjust the output flux gate and other parameters.
  - Monitor real-time statistics and ensure safe operation.

- **Alerts**:
  - Pay attention to on-screen alerts for low fuel or other critical statuses.

## Disclaimer

This program is not fully tested, and I am not responsible for any damage or issues that may occur. Use it at your own risk.

## Contributions and Suggestions

I am not a great debugger, and any help towards improving this program would be greatly appreciated. Please feel free to fork the repository, submit issues, and create pull requests with any improvements or suggestions.

## Contributing

Contributions are welcome! Please fork the repository and submit pull requests for any improvements or fixes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contact

For issues, questions, or suggestions, please open an issue on the GitHub repository.
