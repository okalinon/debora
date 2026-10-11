# Стилі вікна: classic (бічна панель з кольоровими плитками, Apple HIG), focus (вузька рейка зі значками,
# велика цифра оцінки, один «чорнильний» акцент), swiss (вкладки рядком угорі, лінії замість карток,
# без заокруглень, великий жирний шрифт). Стиль змінює лише розмітку: у MainWindow.xaml позначено блоки
# <!--S:НАЗВА-->…<!--/S:НАЗВА-->, які тут підміняються, плюс кілька замін токенів. Усі елементи з x:Name
# мають бути в кожному варіанті (код шукає їх через FindName).
# Порядок у Show-D9Gui: стиль → мова (тексти вставлених блоків теж перекладаються) → темна тема.
# «Чорнило» — #1D1D1F (у темній темі стає світлим), текст на ньому — #F2F2F7 (у темній стає темним).

$script:D9Style = 'classic'
$script:D9Styles = @('classic', 'focus', 'swiss')
$script:D9StyleNames = @{ classic = 'Класичний'; focus = 'Фокус'; swiss = 'Швейцарський' }

# Збережений вибір (HKCU:\Software\Debora\Style), інакше класичний
function Resolve-D9Style {
    param([string]$Style)
    if ($Style -and $Style -ne 'auto' -and $script:D9Styles -contains $Style) { return $Style }
    $saved = (Get-ItemProperty 'HKCU:\Software\Debora' -Name Style -ErrorAction SilentlyContinue).Style
    if ($saved -and $script:D9Styles -contains $saved) { return [string]$saved }
    'classic'
}

function Save-D9Style {
    param([Parameter(Mandatory)][string]$Style)
    try {
        if (-not (Test-Path 'HKCU:\Software\Debora')) { New-Item 'HKCU:\Software\Debora' -Force | Out-Null }
        Set-ItemProperty 'HKCU:\Software\Debora' -Name Style -Value $Style
    } catch { }
}

function Get-D9NextStyle {
    param([string]$Style = $script:D9Style)
    $i = [array]::IndexOf($script:D9Styles, $Style)
    $script:D9Styles[($i + 1) % $script:D9Styles.Count]
}

# Нижня смуга стану для стилів без бічної панелі: праворуч від «Журналу виконання», на рівні його заголовка.
# ZIndex: журнал оголошено пізніше, і його заголовок на всю ширину інакше перехоплює кліки по кнопках смуги
$script:D9StatusStrip = @'
    <StackPanel Grid.Row="1" Grid.Column="1" Panel.ZIndex="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,4,42,0">
      <ProgressBar x:Name="Progress" Width="120" Height="5" Margin="0,0,12,0" VerticalAlignment="Center" Visibility="Collapsed"/>
      <TextBlock x:Name="StatusText" Foreground="#6E6E73" FontSize="13.5" Text="Готово" MaxWidth="360" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
      <TextBlock x:Name="AdminBadge" FontSize="13.5" FontWeight="Medium" Margin="16,0,0,0" MaxWidth="300" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
      <Button x:Name="BtnLanguage" Style="{StaticResource LinkButton}" Content="English" Margin="16,0,0,0" VerticalAlignment="Center" ToolTip="Українська / English"/>
      <Button x:Name="BtnStyle" Style="{StaticResource LinkButton}" Content="Стиль" Margin="14,0,0,0" VerticalAlignment="Center" ToolTip="Класичний → Фокус → Швейцарський"/>
      <TextBlock x:Name="TitleText" Visibility="Collapsed"/>
      <TextBlock x:Name="SystemLine" Visibility="Collapsed"/>
    </StackPanel>
'@

# Оцінка великою цифрою замість кільця (кільце лишається, але приховане — його заповнює той самий код)
function Get-D9ScoreBlock {
    param([int]$Size, [string]$Weight)
    @"
<StackPanel DockPanel.Dock="Left" Margin="0,0,44,0" VerticalAlignment="Center">
                <Path x:Name="ScoreRing" Visibility="Collapsed"/>
                <TextBlock x:Name="ScoreText" Text="—" FontFamily="{StaticResource Display}" FontSize="$Size" FontWeight="$Weight" LineHeight="$Size" LineStackingStrategy="BlockLineHeight"/>
                <TextBlock Text="зі 100" Foreground="#6E6E73" FontSize="14" Margin="4,2,0,0"/>
              </StackPanel>
"@
}

$script:D9StyleParts = @{
    focus = @{
        GRIDCOLS = '<Grid.ColumnDefinitions><ColumnDefinition Width="72"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>'
        SIDEBAR  = @'
    <Border Grid.RowSpan="2" Background="#E9E9EE" BorderBrush="#DCDCE1" BorderThickness="0,0,1,0"/>
    <Border Width="42" Height="42" CornerRadius="11" Background="#1D1D1F" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,22,0,0">
      <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="#F2F2F7" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
'@ + $script:D9StatusStrip
        TABITEM  = @'
<Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#1D1D1F"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="ToolTip" Value="{Binding Header, RelativeSource={RelativeSource Self}}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Width="44" Height="44" Margin="14,3" CornerRadius="11" Background="Transparent" Cursor="Hand">
              <TextBlock x:Name="Ic" Text="{TemplateBinding Tag}" FontFamily="{StaticResource Icons}" FontSize="18" Foreground="#6E6E73" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#DCDCE1"/><Setter TargetName="Ic" Property="Foreground" Value="#1D1D1F"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1D1D1F"/><Setter TargetName="Ic" Property="Foreground" Value="#F2F2F7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
        TABCONTROL = @'
<Style TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="72"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel IsItemsHost="True" Margin="0,84,0,0" KeyboardNavigation.TabNavigation="Once" KeyboardNavigation.DirectionalNavigation="Cycle"/>
              <DockPanel Grid.Column="1">
                <TextBlock DockPanel.Dock="Top" Text="{Binding SelectedItem.Header, RelativeSource={RelativeSource TemplatedParent}}"
                           FontFamily="{StaticResource Display}" FontSize="32" FontWeight="Bold" Margin="48,30,40,14"/>
                <ContentPresenter ContentSource="SelectedContent" Margin="28,0,28,0"/>
              </DockPanel>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
        SCORE = (Get-D9ScoreBlock 96 'Bold')
    }
    swiss = @{
        GRIDCOLS = '<Grid.ColumnDefinitions><ColumnDefinition Width="0"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>'
        SIDEBAR  = $script:D9StatusStrip
        TABITEM  = @'
<Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#6E6E73"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Padding="0,16,0,11" Margin="0,0,17,0" BorderThickness="0,0,0,3" BorderBrush="Transparent" Background="Transparent" Cursor="Hand">
              <ContentPresenter x:Name="Hd" ContentSource="Header" TextElement.FontSize="14" TextElement.Foreground="#6E6E73"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hd" Property="TextElement.Foreground" Value="#1D1D1F"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#1D1D1F"/>
                <Setter TargetName="Hd" Property="TextElement.Foreground" Value="#1D1D1F"/>
                <Setter TargetName="Hd" Property="TextElement.FontWeight" Value="Bold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
        TABCONTROL = @'
<Style TargetType="TabControl">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <DockPanel>
              <Border DockPanel.Dock="Top" BorderBrush="#1D1D1F" BorderThickness="0,0,0,2" Margin="40,6,40,0">
                <DockPanel>
                  <TextBlock DockPanel.Dock="Left" Text="Debora" FontFamily="{StaticResource Display}" FontSize="18" FontWeight="Black" VerticalAlignment="Center" Margin="0,0,24,0"/>
                  <WrapPanel IsItemsHost="True" KeyboardNavigation.TabNavigation="Once" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </DockPanel>
              </Border>
              <TextBlock DockPanel.Dock="Top" Text="{Binding SelectedItem.Header, RelativeSource={RelativeSource TemplatedParent}}"
                         FontFamily="{StaticResource Display}" FontSize="44" FontWeight="Black" Margin="40,22,40,10"/>
              <ContentPresenter ContentSource="SelectedContent" Margin="20,0,20,0"/>
            </DockPanel>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@
        SECTION = @'
<Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#1D1D1F"/>
      <Setter Property="Margin" Value="20,28,0,8"/>
    </Style>
'@
        # Картки й групи — без заливки й заокруглень, лише лінія зверху (типографічна сітка)
        BLOCKS = @'
<Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#1D1D1F"/>
      <Setter Property="BorderThickness" Value="0,2,0,0"/>
      <Setter Property="Padding" Value="20,18"/>
    </Style>
    <Style x:Key="Group" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#1D1D1F"/>
      <Setter Property="BorderThickness" Value="0,2,0,0"/>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#1D1D1F"/>
      <Setter Property="BorderThickness" Value="0,2,0,0"/>
      <Setter Property="Padding" Value="8"/>
    </Style>

'@
        SCORE = (Get-D9ScoreBlock 120 'Black')
    }
}

function Convert-D9XamlStyle {
    param([Parameter(Mandatory)][string]$Xaml, [string]$Style = $script:D9Style)
    if ($Style -eq 'classic' -or -not $script:D9StyleParts.ContainsKey($Style)) { return $Xaml }
    $parts = $script:D9StyleParts[$Style]
    foreach ($name in $parts.Keys) {
        $Xaml = [regex]::Replace($Xaml, "(?s)<!--S:$name-->.*?<!--/S:$name-->", { param($m) $parts[$name] }.GetNewClosure())
    }
    # Головна кнопка — «чорнильна» (у темній темі інвертується разом з палітрою)
    $Xaml = [regex]::Replace($Xaml, '(?s)(<Style x:Key="Primary".*?<Setter Property="Background" Value=")#007AFF("/>\s*<Setter Property="Foreground" Value=")#FFFFFF', '${1}#1D1D1F${2}#F2F2F7')
    if ($Style -eq 'swiss') {
        $Xaml = [regex]::Replace($Xaml, 'CornerRadius="[^"]*"', 'CornerRadius="0"')
        $Xaml = [regex]::Replace($Xaml, '(Property="CornerRadius" Value=")[^"]*"', '${1}0"')
        # Тло вікна — біле: картки зливаються з ним, а розділяють їх лінії
        $Xaml = $Xaml.Replace('Background="#F2F2F7" Foreground="#1D1D1F"', 'Background="White" Foreground="#1D1D1F"')
    }
    $Xaml
}

function Get-D9StyleName {
    param([string]$Style = $script:D9Style)
    T-D9 $script:D9StyleNames[$Style]
}
