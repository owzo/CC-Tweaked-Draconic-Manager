# CC:Tweaked-Draconic Manager

## Description

CC:Tweaked-Draconic Manager is a comprehensive control and monitoring program designed for ComputerCraft: Tweaked to manage Draconic Evolution reactors and energy cores. This system ensures the safe and efficient operation of your reactors and energy storage, leveraging wireless modem communication for a seamless and flexible setup.

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
